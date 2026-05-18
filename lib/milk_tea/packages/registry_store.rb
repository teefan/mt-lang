# frozen_string_literal: true

require "cgi/escape"
require "fileutils"
require "tmpdir"
require "uri"

require_relative "../tooling/archive_tool"
require_relative "../tooling/http_fetch_tool"

module MilkTea
  class PackageRegistryStoreError < StandardError; end

  class PackageRegistryStore
    Result = Data.define(:package_name, :version, :path)

    def self.default_root(env: ENV, home: nil)
      explicit_root = env.fetch("MILK_TEA_PACKAGE_REGISTRY", "").to_s.strip
      return File.expand_path(explicit_root) unless explicit_root.empty?

      xdg_data_home = env.fetch("XDG_DATA_HOME", "").to_s.strip
      base_root = if xdg_data_home.empty?
                    File.join(home || Dir.home, ".local", "share")
                  else
                    File.expand_path(xdg_data_home)
                  end

      File.join(base_root, "milk_tea", "registry")
    end

    def self.default_upstream_root(env: ENV)
      explicit_root = env.fetch("MILK_TEA_PACKAGE_REGISTRY_UPSTREAM", "").to_s.strip
      return nil if explicit_root.empty?

      http_url?(explicit_root) ? explicit_root : File.expand_path(explicit_root)
    end

    def self.http_url?(value)
      uri = URI.parse(value.to_s)
      %w[http https].include?(uri.scheme)
    rescue URI::InvalidURIError
      false
    end

    attr_reader :root, :upstream_root

    def initialize(root: self.class.default_root, upstream_root: self.class.default_upstream_root)
      @root = File.expand_path(root)
      @upstream_root = normalize_optional_root(upstream_root)
    end

    def package_root_for(package_or_identity, version = nil)
      package_name, package_version = extract_package_version(package_or_identity, version)

      File.join(@root, "packages", normalize_component(package_name, "package name"), normalize_component(package_version, "package version"))
    end

    def manifest_path_for(package_or_identity, version = nil)
      File.join(package_root_for(package_or_identity, version), "package.toml")
    end

    def published?(package_or_identity, version = nil)
      File.file?(manifest_path_for(package_or_identity, version))
    end

    def published_root_for(package_or_identity, version = nil, sync: false)
      package_name, package_version = extract_package_version(package_or_identity, version)
      sync(package_name, package_version) if sync && !published?(package_name, package_version) && upstream_configured?
      manifest_path = manifest_path_for(package_name, package_version)
      unless File.file?(manifest_path)
        raise PackageRegistryStoreError,
              "registry package #{package_name} version #{package_version} not found in #{@root}"
      end

      package_root_for(package_name, package_version)
    end

    def available_versions(package_name)
      versions = package_versions_for_root(@root, package_name)
      if upstream_configured?
        upstream_versions = if upstream_http?
                              package_versions_for_http(package_name)
                            else
                              package_versions_for_root(@upstream_root, package_name)
                            end
        versions = upstream_versions + versions
      end

      versions.uniq
    end

    def publish(path, target: :local)
      manifest = PackageManifest.load(path)
      package_version = manifest.package_version.to_s.strip
      if package_version.empty?
        raise PackageRegistryStoreError,
              "package #{manifest.package_name} at #{manifest.manifest_path} must declare package.version before publishing"
      end

      target_root = registry_root_for_target(target)
      package_root = package_root_for_root(target_root, manifest.package_name, package_version)
      if File.exist?(package_root)
        raise PackageRegistryStoreError,
              "package #{manifest.package_name} version #{package_version} already published in registry: #{package_root}"
      end

      FileUtils.mkdir_p(File.dirname(package_root))
      FileUtils.copy_entry(manifest.root_dir, package_root)
      write_registry_artifacts!(target_root, manifest.package_name, package_version, package_root)

      Result.new(package_name: manifest.package_name, version: package_version, path: package_root)
    rescue PackageManifestError => e
      raise PackageRegistryStoreError, e.message
    rescue SystemCallError => e
      raise PackageRegistryStoreError, "failed to publish package to #{target_root || @root}: #{e.message}"
    end

    def sync(package_or_identity, version = nil)
      package_name, package_version = extract_package_version(package_or_identity, version)
      raise PackageRegistryStoreError, "registry upstream is not configured" unless upstream_configured?

      local_root = package_root_for(package_name, package_version)
      return Result.new(package_name:, version: package_version, path: local_root) if published?(package_name, package_version)

      return sync_from_http(package_name, package_version, local_root) if upstream_http?

      upstream_package_root = package_root_for_root(@upstream_root, package_name, package_version)
      upstream_manifest_path = File.join(upstream_package_root, "package.toml")
      unless File.file?(upstream_manifest_path)
        raise PackageRegistryStoreError,
              "registry package #{package_name} version #{package_version} not found in upstream registry #{@upstream_root}"
      end

      upstream_manifest = PackageManifest.load(upstream_package_root)
      if upstream_manifest.package_name != package_name || upstream_manifest.package_version != package_version
        raise PackageRegistryStoreError,
              "upstream registry package at #{upstream_manifest.manifest_path} resolved to #{upstream_manifest.package_name}@#{upstream_manifest.package_version.inspect}; expected #{package_name}@#{package_version}"
      end

      FileUtils.rm_rf(local_root) if File.exist?(local_root)
      FileUtils.mkdir_p(File.dirname(local_root))
      FileUtils.copy_entry(upstream_package_root, local_root)
      write_registry_artifacts!(@root, package_name, package_version, local_root)

      Result.new(package_name:, version: package_version, path: local_root)
    rescue PackageManifestError => e
      raise PackageRegistryStoreError, e.message
    rescue SystemCallError => e
      raise PackageRegistryStoreError, "failed to sync package from upstream registry #{@upstream_root}: #{e.message}"
    end

    def upstream_configured?
      !@upstream_root.nil?
    end

    def upstream_http?
      self.class.http_url?(@upstream_root)
    end

    private

    def extract_package_version(package_or_identity, version)
      if package_or_identity.respond_to?(:package_name) && package_or_identity.respond_to?(:version)
        [package_or_identity.package_name, package_or_identity.version]
      else
        [package_or_identity, version]
      end
    end

    def normalize_component(value, label)
      text = value.to_s.strip
      raise PackageRegistryStoreError, "#{label} cannot be empty" if text.empty?

      separators = [File::SEPARATOR, File::ALT_SEPARATOR].compact
      if separators.any? { |separator| text.include?(separator) } || text == "." || text == ".."
        raise PackageRegistryStoreError, "#{label} contains an unsupported path separator: #{text.inspect}"
      end

      text
    end

    def package_root_for_root(root, package_or_identity, version = nil)
      package_name, package_version = extract_package_version(package_or_identity, version)

      File.join(root, "packages", normalize_component(package_name, "package name"), normalize_component(package_version, "package version"))
    end

    def archive_path_for_root(root, package_name, package_version)
      package_dir = File.join(root, "packages", normalize_component(package_name, "package name"))
      File.join(package_dir, "#{normalize_component(package_version, "package version")}.tar.gz")
    end

    def versions_index_path_for_root(root, package_name)
      File.join(root, "packages", normalize_component(package_name, "package name"), "versions.txt")
    end

    def package_versions_for_root(root, package_name)
      return [] if root.nil?

      package_dir = File.join(root, "packages", normalize_component(package_name, "package name"))
      return [] unless File.directory?(package_dir)

      Dir.children(package_dir).sort.each_with_object([]) do |entry, versions|
        next if entry.start_with?(".") || entry == "versions.txt" || entry.end_with?(".tar.gz")

        manifest_path = File.join(package_dir, entry, "package.toml")
        versions << entry if File.file?(manifest_path)
      end
    rescue SystemCallError => e
      raise PackageRegistryStoreError, "failed to inspect registry package versions under #{package_dir}: #{e.message}"
    end

    def package_versions_for_http(package_name)
      Dir.mktmpdir("milk-tea-registry-versions") do |tmpdir|
        body_path = File.join(tmpdir, "versions.txt")
        response = http_fetch_to_file(package_versions_url(package_name), body_path)
        return [] if response.not_found?
        raise_http_error!(response, "list registry package versions") unless response.success?

        return File.read(body_path).lines.map(&:strip).reject(&:empty?)
      end
    end

    def sync_from_http(package_name, package_version, local_root)
      FileUtils.rm_rf(local_root) if File.exist?(local_root)
      FileUtils.mkdir_p(File.dirname(local_root))

      Dir.mktmpdir("milk-tea-http-registry", File.dirname(local_root)) do |tmpdir|
        archive_path = File.join(tmpdir, "package.tar.gz")
        response = http_fetch_to_file(package_archive_url(package_name, package_version), archive_path)
        if response.not_found?
          raise PackageRegistryStoreError,
                "registry package #{package_name} version #{package_version} not found in upstream registry #{@upstream_root}"
        end
        raise_http_error!(response, "download registry package archive") unless response.success?

        extract_archive_path_to_root(archive_path, local_root)
      end

      validate_synced_package!(local_root, package_name, package_version)
      write_registry_artifacts!(@root, package_name, package_version, local_root)

      Result.new(package_name:, version: package_version, path: local_root)
    rescue PackageManifestError => e
      raise PackageRegistryStoreError, e.message
    rescue SystemCallError => e
      raise PackageRegistryStoreError, "failed to sync package from upstream registry #{@upstream_root}: #{e.message}"
    end

    def validate_synced_package!(package_root, package_name, package_version)
      manifest = PackageManifest.load(package_root)
      if manifest.package_name != package_name || manifest.package_version != package_version
        raise PackageRegistryStoreError,
              "upstream registry package at #{manifest.manifest_path} resolved to #{manifest.package_name}@#{manifest.package_version.inspect}; expected #{package_name}@#{package_version}"
      end
    end

    def write_registry_artifacts!(root, package_name, package_version, package_root)
      write_package_archive!(archive_path_for_root(root, package_name, package_version), package_root)
      write_versions_index!(root, package_name)
    end

    def write_package_archive!(archive_path, package_root)
      FileUtils.mkdir_p(File.dirname(archive_path))

      ArchiveTool.archive_directory(
        source_root: package_root,
        archive_path:,
        archive_root_name: "",
        include_hidden: false,
      )
    rescue ArchiveToolError => e
      raise PackageRegistryStoreError, e.message
    end

    def write_versions_index!(root, package_name)
      path = versions_index_path_for_root(root, package_name)
      versions = package_versions_for_root(root, package_name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, versions.join("\n") + (versions.empty? ? "" : "\n"))
    end

    def extract_archive_to_root(archive_body, destination_root, scratch_dir)
      archive_path = File.join(scratch_dir, "package.tar.gz")
      File.binwrite(archive_path, archive_body)
      extract_archive_path_to_root(archive_path, destination_root)
    rescue ArchiveToolError => e
      raise PackageRegistryStoreError, e.message
    end

    def extract_archive_path_to_root(archive_path, destination_root)
      extract_root = File.join(File.dirname(archive_path), "extract")
      ArchiveTool.extract_archive(archive_path:, destination_root: extract_root)

      FileUtils.mv(extract_root, destination_root)
    rescue ArchiveToolError => e
      raise PackageRegistryStoreError, e.message
    end

    def package_versions_url(package_name)
      join_upstream_url("packages", package_name, "versions.txt")
    end

    def package_archive_url(package_name, package_version)
      join_upstream_url("packages", package_name, "#{package_version}.tar.gz")
    end

    def join_upstream_url(*segments)
      encoded_segments = segments.map do |segment|
        CGI.escape(segment.to_s).gsub("+", "%20")
      end
      base = @upstream_root.to_s.sub(%r{/+\z}, "")
      "#{base}/#{encoded_segments.join("/")}"
    end

    def http_fetch_to_file(url, body_path)
      HttpFetchTool.fetch_to_file(url:, body_path:)
    rescue HttpFetchToolError => e
      raise PackageRegistryStoreError, e.message
    end

    def raise_http_error!(response, action)
      raise PackageRegistryStoreError,
            "failed to #{action} from upstream registry #{@upstream_root}: HTTP #{response.status_code} #{response.reason}"
    end

    def normalize_optional_root(root)
      text = root.to_s.strip
      return nil if text.empty?

      self.class.http_url?(text) ? text.sub(%r{/+\z}, "") : File.expand_path(text)
    end

    def registry_root_for_target(target)
      case target
      when :local
        @root
      when :upstream
        raise PackageRegistryStoreError, "registry upstream is not configured" unless upstream_configured?
        if upstream_http?
          raise PackageRegistryStoreError,
                "publishing directly to an HTTP registry upstream is not supported; publish to a filesystem mirror instead"
        end

        @upstream_root
      else
        raise PackageRegistryStoreError, "unknown registry publish target #{target.inspect}"
      end
    end
  end
end
