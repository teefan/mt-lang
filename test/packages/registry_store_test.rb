# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaPackageRegistryStoreTest < Minitest::Test
  def test_default_root_prefers_explicit_registry_env_over_xdg_data_home
    root = MilkTea::PackageRegistryStore.default_root(
      env: {
        "MILK_TEA_PACKAGE_REGISTRY" => "/tmp/custom-registry",
        "XDG_DATA_HOME" => "/tmp/xdg-data",
      },
      home: "/tmp/home",
    )

    assert_equal File.expand_path("/tmp/custom-registry"), root
  end

  def test_default_upstream_root_uses_explicit_env_when_present
    root = MilkTea::PackageRegistryStore.default_upstream_root(
      env: {
        "MILK_TEA_PACKAGE_REGISTRY_UPSTREAM" => "/tmp/upstream-registry",
      },
    )

    assert_equal File.expand_path("/tmp/upstream-registry"), root
  end

  def test_default_upstream_root_preserves_http_url
    root = MilkTea::PackageRegistryStore.default_upstream_root(
      env: {
        "MILK_TEA_PACKAGE_REGISTRY_UPSTREAM" => "https://packages.example.test/registry",
      },
    )

    assert_equal "https://packages.example.test/registry", root
  end

  def test_publish_copies_package_root_and_rejects_overwrite
    Dir.mktmpdir("milk-tea-package-registry-store") do |dir|
      package_root = File.join(dir, "packages", "ui")
      registry_root = File.join(dir, "registry")

      FileUtils.mkdir_p(File.join(package_root, "src", "teefan", "ui"))
      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML
      File.write(File.join(package_root, "src", "teefan", "ui", "layout.mt"), <<~MT)
      MT

      store = MilkTea::PackageRegistryStore.new(root: registry_root)

      result = store.publish(package_root)

      assert_equal "teefan.ui", result.package_name
      assert_equal "1.2.3", result.version
      assert_equal File.expand_path(File.join(registry_root, "packages", "teefan.ui", "1.2.3")), result.path
      assert File.file?(File.join(result.path, "package.toml"))
      assert File.file?(File.join(result.path, "src", "teefan", "ui", "layout.mt"))

      error = assert_raises(MilkTea::PackageRegistryStoreError) do
        store.publish(package_root)
      end

      assert_match(/already published/, error.message)
    end
  end

  def test_publish_can_target_upstream_and_sync_back_to_local_registry
    Dir.mktmpdir("milk-tea-package-registry-store-upstream") do |dir|
      package_root = File.join(dir, "packages", "ui")
      registry_root = File.join(dir, "registry")
      upstream_root = File.join(dir, "upstream-registry")

      FileUtils.mkdir_p(File.join(package_root, "src", "teefan", "ui"))
      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML
      File.write(File.join(package_root, "src", "teefan", "ui", "layout.mt"), <<~MT)
      MT

      store = MilkTea::PackageRegistryStore.new(root: registry_root, upstream_root: upstream_root)

      publish_result = store.publish(package_root, target: :upstream)

      assert_equal File.expand_path(File.join(upstream_root, "packages", "teefan.ui", "1.2.3")), publish_result.path
      refute store.published?("teefan.ui", "1.2.3")

      sync_result = store.sync("teefan.ui", "1.2.3")

      assert_equal File.expand_path(File.join(registry_root, "packages", "teefan.ui", "1.2.3")), sync_result.path
      assert store.published?("teefan.ui", "1.2.3")
      assert File.file?(File.join(sync_result.path, "src", "teefan", "ui", "layout.mt"))
    end
  end

  def test_sync_can_download_package_from_http_upstream
    Dir.mktmpdir("milk-tea-package-registry-store-http") do |dir|
      package_root = File.join(dir, "packages", "ui")
      registry_root = File.join(dir, "registry")
      upstream_root = File.join(dir, "upstream-registry")

      FileUtils.mkdir_p(File.join(package_root, "src", "teefan", "ui"))
      File.write(File.join(package_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML
      File.write(File.join(package_root, "src", "teefan", "ui", "layout.mt"), <<~MT)
      MT

      publisher = MilkTea::PackageRegistryStore.new(root: registry_root, upstream_root: upstream_root)
      publisher.publish(package_root, target: :upstream)

      with_static_http_server(upstream_root) do |base_url|
        store = MilkTea::PackageRegistryStore.new(root: registry_root, upstream_root: base_url)

        sync_result = store.sync("teefan.ui", "1.2.3")

        assert_equal File.expand_path(File.join(registry_root, "packages", "teefan.ui", "1.2.3")), sync_result.path
        assert store.published?("teefan.ui", "1.2.3")
        assert File.file?(File.join(sync_result.path, "src", "teefan", "ui", "layout.mt"))
        assert File.file?(File.join(registry_root, "packages", "teefan.ui", "1.2.3.tar.gz"))
        assert_equal ["1.2.3"], File.read(File.join(registry_root, "packages", "teefan.ui", "versions.txt")).lines.map(&:strip)
      end
    end
  end
end
