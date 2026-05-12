# frozen_string_literal: true

require "fileutils"

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

      File.expand_path(explicit_root)
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

      Result.new(package_name:, version: package_version, path: local_root)
    rescue PackageManifestError => e
      raise PackageRegistryStoreError, e.message
    rescue SystemCallError => e
      raise PackageRegistryStoreError, "failed to sync package from upstream registry #{@upstream_root}: #{e.message}"
    end

    def upstream_configured?
      !@upstream_root.nil?
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

    def normalize_optional_root(root)
      text = root.to_s.strip
      return nil if text.empty?

      File.expand_path(text)
    end

    def registry_root_for_target(target)
      case target
      when :local
        @root
      when :upstream
        raise PackageRegistryStoreError, "registry upstream is not configured" unless upstream_configured?

        @upstream_root
      else
        raise PackageRegistryStoreError, "unknown registry publish target #{target.inspect}"
      end
    end
  end
end
