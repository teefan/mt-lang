# frozen_string_literal: true

module MilkTea
  class PackageRegistryMetadataProviderError < StandardError; end

  class PackageRegistryMetadataProvider
    def initialize(registry_store: PackageRegistryStore.new)
      @registry_store = registry_store
    end

    def available_versions(package_name)
      @registry_store.available_versions(package_name).map do |version_text|
        PackageVersion.parse(version_text, label: "registry package #{package_name} version")
      end.sort.reverse
    rescue PackageRegistryStoreError, PackageVersionError => e
      raise PackageRegistryMetadataProviderError, e.message
    end

    def manifest_for(package_name, version)
      version_text = version.to_s
      package_root = @registry_store.published_root_for(package_name, version_text, sync: true)

      manifest = PackageManifest.load(package_root)
      if manifest.package_name != package_name || manifest.package_version != version_text
        raise PackageRegistryMetadataProviderError,
              "registry package at #{manifest.manifest_path} resolved to #{manifest.package_name}@#{manifest.package_version.inspect}; expected #{package_name}@#{version_text}"
      end

      manifest
    rescue PackageManifestError, PackageRegistryStoreError => e
      raise PackageRegistryMetadataProviderError, e.message
    end
  end
end
