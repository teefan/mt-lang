# frozen_string_literal: true

module MilkTea
  class PackageRegistryMetadataProviderError < StandardError; end

  class PackageRegistryMetadataProvider
    def initialize(registry_store: PackageRegistryStore.new)
      @registry_store = registry_store
      @roots_by_package_name = {}
    end

    def available_versions(package_name)
      roots_for_package(package_name).keys.map do |version_text|
        PackageVersion.parse(version_text, label: "registry package #{package_name} version")
      end.sort.reverse
    rescue PackageVersionError => e
      raise PackageRegistryMetadataProviderError, e.message
    end

    def manifest_for(package_name, version)
      version_text = version.to_s
      package_root = roots_for_package(package_name)[version_text]
      unless package_root
        raise PackageRegistryMetadataProviderError,
              "registry package #{package_name} version #{version_text} not found in #{registry_locations_label}"
      end

      manifest = PackageManifest.load(package_root)
      if manifest.package_name != package_name || manifest.package_version != version_text
        raise PackageRegistryMetadataProviderError,
              "registry package at #{manifest.manifest_path} resolved to #{manifest.package_name}@#{manifest.package_version.inspect}; expected #{package_name}@#{version_text}"
      end

      manifest
    rescue PackageManifestError => e
      raise PackageRegistryMetadataProviderError, e.message
    end

    private

    def roots_for_package(package_name)
      package_key = package_name.to_s
      return @roots_by_package_name[package_key] if @roots_by_package_name.key?(package_key)

      roots = package_roots_for(@registry_store.upstream_root, package_key)
      roots.merge!(package_roots_for(@registry_store.root, package_key))
      @roots_by_package_name[package_key] = roots
    end

    def package_roots_for(root, package_name)
      return {} if root.nil?

      package_dir = File.join(root, "packages", package_name)
      return {} unless File.directory?(package_dir)

      Dir.children(package_dir).sort.each_with_object({}) do |entry, roots|
        next if entry.start_with?(".")

        package_root = File.join(package_dir, entry)
        manifest_path = File.join(package_root, "package.toml")
        next unless File.directory?(package_root) && File.file?(manifest_path)

        roots[entry] = package_root
      end
    rescue SystemCallError => e
      raise PackageRegistryMetadataProviderError,
            "failed to inspect registry metadata under #{package_dir}: #{e.message}"
    end

    def registry_locations_label
      locations = [@registry_store.root]
      locations << @registry_store.upstream_root if @registry_store.upstream_configured?
      locations.compact.join(" or ")
    end
  end
end
