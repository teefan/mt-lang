# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaPackageRegistryMetadataProviderTest < Minitest::Test
  def test_available_versions_returns_sorted_descending_versions
    Dir.mktmpdir("milk-tea-registry-metadata-versions") do |dir|
      registry_root = File.join(dir, "registry")
      published_root = File.join(dir, "published")
      FileUtils.mkdir_p(File.join(published_root, "src"))

      File.write(File.join(published_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML

      store = MilkTea::PackageRegistryStore.new(root: registry_root)
      store.publish(published_root)

      published_root2 = File.join(dir, "published2")
      FileUtils.mkdir_p(File.join(published_root2, "src"))
      File.write(File.join(published_root2, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "2.0.0"
        kind = "library"
        source_root = "src"
      TOML

      store.publish(published_root2)

      provider = MilkTea::PackageRegistryMetadataProvider.new(registry_store: store)

      versions = provider.available_versions("teefan.ui")

      assert_equal 2, versions.length
      assert_operator versions[0], :>, versions[1]
    end
  end

  def test_available_versions_returns_empty_for_unknown_package
    Dir.mktmpdir("milk-tea-registry-metadata-unknown") do |dir|
      registry_root = File.join(dir, "registry")
      store = MilkTea::PackageRegistryStore.new(root: registry_root)
      provider = MilkTea::PackageRegistryMetadataProvider.new(registry_store: store)

      versions = provider.available_versions("nonexistent.package")

      assert_equal [], versions
    end
  end

  def test_manifest_for_returns_correct_manifest_and_validates_identity
    Dir.mktmpdir("milk-tea-registry-metadata-manifest") do |dir|
      registry_root = File.join(dir, "registry")
      published_root = File.join(dir, "published")
      FileUtils.mkdir_p(File.join(published_root, "src", "teefan", "ui"))

      File.write(File.join(published_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML
      File.write(File.join(published_root, "src", "teefan", "ui", "layout.mt"), "module layout\n")

      store = MilkTea::PackageRegistryStore.new(root: registry_root)
      store.publish(published_root)

      provider = MilkTea::PackageRegistryMetadataProvider.new(registry_store: store)

      version = MilkTea::PackageVersion.new(1, 2, 3)
      manifest = provider.manifest_for("teefan.ui", version)

      assert_equal "teefan.ui", manifest.package_name
      assert_equal "1.2.3", manifest.package_version
      assert File.directory?(File.join(manifest.root_dir, "src", "teefan", "ui"))
    end
  end

  def test_manifest_for_rejects_unknown_package
    Dir.mktmpdir("milk-tea-registry-metadata-mismatch") do |dir|
      registry_root = File.join(dir, "registry")
      store = MilkTea::PackageRegistryStore.new(root: registry_root)
      provider = MilkTea::PackageRegistryMetadataProvider.new(registry_store: store)
      version = MilkTea::PackageVersion.new(1, 0, 0)

      error = assert_raises(MilkTea::PackageRegistryMetadataProviderError) do
        provider.manifest_for("unknown.pkg", version)
      end

      assert_match(/unknown\.pkg/, error.message)
    end
  end

  def test_manifest_for_rejects_unknown_version
    Dir.mktmpdir("milk-tea-registry-metadata-version-mismatch") do |dir|
      registry_root = File.join(dir, "registry")
      published_root = File.join(dir, "published")
      FileUtils.mkdir_p(File.join(published_root, "src"))

      File.write(File.join(published_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML

      store = MilkTea::PackageRegistryStore.new(root: registry_root)
      store.publish(published_root)
      provider = MilkTea::PackageRegistryMetadataProvider.new(registry_store: store)
      version = MilkTea::PackageVersion.new(2, 0, 0)

      error = assert_raises(MilkTea::PackageRegistryMetadataProviderError) do
        provider.manifest_for("teefan.ui", version)
      end

      assert_match(/2\.0\.0/, error.message)
    end
  end
end
