# frozen_string_literal: true

require "cgi/escape"
require "fileutils"
require "net/http"
require "rubygems/package"
require "stringio"
require "tmpdir"
require "uri"
require "zlib"

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
      response = http_get_response(package_versions_url(package_name))
      return [] if response.is_a?(Net::HTTPNotFound)
      raise_http_error!(response, "list registry package versions") unless response.is_a?(Net::HTTPSuccess)

      response.body.lines.map(&:strip).reject(&:empty?)
    end

    def sync_from_http(package_name, package_version, local_root)
      response = http_get_response(package_archive_url(package_name, package_version))
      if response.is_a?(Net::HTTPNotFound)
        raise PackageRegistryStoreError,
              "registry package #{package_name} version #{package_version} not found in upstream registry #{@upstream_root}"
      end
      raise_http_error!(response, "download registry package archive") unless response.is_a?(Net::HTTPSuccess)

      FileUtils.rm_rf(local_root) if File.exist?(local_root)
      FileUtils.mkdir_p(File.dirname(local_root))

      Dir.mktmpdir("milk-tea-http-registry", File.dirname(local_root)) do |tmpdir|
        extract_archive_to_root(response.body, local_root, tmpdir)
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

      tar_buffer = StringIO.new(+"")
      Gem::Package::TarWriter.new(tar_buffer) do |tar|
        add_directory_to_archive(tar, package_root, package_root)
      end
      tar_buffer.rewind

      Zlib::GzipWriter.open(archive_path) do |gzip|
        gzip.write(tar_buffer.string)
      end
    end

    def add_directory_to_archive(tar, root_path, path)
      Dir.children(path).sort.each do |entry|
        next if entry.start_with?(".")

        child_path = File.join(path, entry)
        relative_path = child_path.delete_prefix(root_path + File::SEPARATOR)
        stat = File.lstat(child_path)
        if stat.directory?
          tar.mkdir(relative_path, stat.mode)
          add_directory_to_archive(tar, root_path, child_path)
        elsif stat.file?
          tar.add_file(relative_path, stat.mode) do |file|
            File.open(child_path, "rb") do |source|
              IO.copy_stream(source, file)
            end
          end
        end
      end
    end

    def write_versions_index!(root, package_name)
      path = versions_index_path_for_root(root, package_name)
      versions = package_versions_for_root(root, package_name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, versions.join("\n") + (versions.empty? ? "" : "\n"))
    end

    def extract_archive_to_root(archive_body, destination_root, scratch_dir)
      archive_path = File.join(scratch_dir, "package.tar.gz")
      extract_root = File.join(scratch_dir, "extract")
      File.binwrite(archive_path, archive_body)
      FileUtils.mkdir_p(extract_root)

      Zlib::GzipReader.open(archive_path) do |gzip|
        Gem::Package::TarReader.new(gzip) do |tar|
          tar.each do |entry|
            relative_path = entry.full_name
            next if relative_path.nil? || relative_path.empty?

            destination_path = File.expand_path(relative_path, extract_root)
            unless destination_path == extract_root || destination_path.start_with?(extract_root + File::SEPARATOR)
              raise PackageRegistryStoreError, "registry package archive contains an invalid path #{relative_path.inspect}"
            end

            if entry.directory?
              FileUtils.mkdir_p(destination_path)
            elsif entry.file?
              FileUtils.mkdir_p(File.dirname(destination_path))
              File.open(destination_path, "wb", entry.header.mode) do |file|
                IO.copy_stream(entry, file)
              end
            end
          end
        end
      end

      FileUtils.mv(extract_root, destination_root)
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

    def http_get_response(url, redirects_remaining = 5)
      uri = URI.parse(url)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        http.request(Net::HTTP::Get.new(uri.request_uri))
      end

      if response.is_a?(Net::HTTPRedirection)
        raise PackageRegistryStoreError, "too many HTTP redirects while fetching #{url}" if redirects_remaining <= 0

        location = response["location"]
        raise PackageRegistryStoreError, "missing redirect location while fetching #{url}" if location.to_s.strip.empty?

        return http_get_response(URI.join(url, location).to_s, redirects_remaining - 1)
      end

      response
    rescue URI::InvalidURIError => e
      raise PackageRegistryStoreError, "invalid upstream registry URL #{url.inspect}: #{e.message}"
    rescue SocketError, IOError, SystemCallError => e
      raise PackageRegistryStoreError, "failed to fetch #{url}: #{e.message}"
    end

    def raise_http_error!(response, action)
      raise PackageRegistryStoreError,
            "failed to #{action} from upstream registry #{@upstream_root}: HTTP #{response.code} #{response.message}"
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
