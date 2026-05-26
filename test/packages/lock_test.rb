# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaPackageLockTest < Minitest::Test
  def test_write_preserves_original_lockfile_when_atomic_replace_fails
    Dir.mktmpdir("milk-tea-package-lock-atomic") do |dir|
      lock_path = File.join(dir, "package.lock")
      original_content = "old lock\n"
      File.write(lock_path, original_content)

      lock = MilkTea::PackageLock.new(dir)
      lock.define_singleton_method(:rendered_lockfile) do
        [lock_path, "new lock\n"]
      end

      error = with_singleton_method_override(File, :rename, lambda do |*_args|
        raise Errno::EIO, "rename failed"
      end) do
        assert_raises(MilkTea::PackageLockError) do
          lock.write
        end
      end

      assert_match(/failed to write/, error.message)
      assert_equal original_content, File.read(lock_path)
    end
  end

  def test_load_supports_duplicate_package_names_when_schema_uses_package_instance_ids
    Dir.mktmpdir("milk-tea-package-lock-instance-ids") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_v1_root = File.join(dir, "libs", "ui-v1")
      ui_v2_root = File.join(dir, "libs", "ui-v2")
      app_src_dir = File.join(app_root, "src")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(File.join(ui_v1_root, "src"))
      FileUtils.mkdir_p(File.join(ui_v2_root, "src"))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"
      TOML

      File.write(File.join(ui_v1_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.0.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(ui_v2_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "2.0.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(app_root, "package.lock"), <<~LOCK)
        schema_version = 2
        root_package = "snake_duel"
        root_package_id = "root"

        [[package]]
        instance_id = "root"
        name = "snake_duel"
        kind = "application"
        version = "0.1.0"
        source_kind = "path"
        source_path = #{app_root.inspect}
        manifest_path = #{File.join(app_root, "package.toml").inspect}
        source_root = #{app_src_dir.inspect}
        dependency_ids = ["ui-v1", "ui-v2"]

        [[package]]
        instance_id = "ui-v1"
        name = "teefan.ui"
        kind = "library"
        version = "1.0.0"
        source_kind = "path"
        source_path = #{ui_v1_root.inspect}
        manifest_path = #{File.join(ui_v1_root, "package.toml").inspect}
        source_root = #{File.join(ui_v1_root, "src").inspect}
        dependency_ids = []

        [[package]]
        instance_id = "ui-v2"
        name = "teefan.ui"
        kind = "library"
        version = "2.0.0"
        source_kind = "path"
        source_path = #{ui_v2_root.inspect}
        manifest_path = #{File.join(ui_v2_root, "package.toml").inspect}
        source_root = #{File.join(ui_v2_root, "src").inspect}
        dependency_ids = []
      LOCK

      root = MilkTea::PackageLock.load(app_root)

      assert_equal "snake_duel", root.manifest.package_name
      assert_equal ["1.0.0", "2.0.0"], root.edges.map { |edge| edge.node.manifest.package_version }.sort
    end
  end

  def test_load_uses_materialized_cache_root_for_registry_source_entries
    Dir.mktmpdir("milk-tea-package-lock-cache-root") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      app_src_dir = File.join(app_root, "src")
      cache_root = File.join(dir, "cache")
      registry_root = File.join(cache_root, "registry", "teefan.ui@1.2.3")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(File.join(registry_root, "src"))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"
      TOML

      File.write(File.join(registry_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(app_root, "package.lock"), <<~LOCK)
        schema_version = 1
        root_package = "snake_duel"

        [[package]]
        name = "snake_duel"
        kind = "application"
        version = "0.1.0"
        source_kind = "path"
        source_path = #{app_root.inspect}
        manifest_path = #{File.join(app_root, "package.toml").inspect}
        source_root = #{app_src_dir.inspect}
        dependencies = ["teefan.ui"]

        [[package]]
        name = "teefan.ui"
        kind = "library"
        version = "1.2.3"
        source_kind = "registry"
        registry_package = "teefan.ui"
        registry_version = "1.2.3"
        manifest_path = #{File.join(registry_root, "package.toml").inspect}
        source_root = #{File.join(registry_root, "src").inspect}
        dependencies = []
      LOCK

      source_resolver = MilkTea::PackageSourceResolver.new(
        source_cache: MilkTea::PackageSourceCache.new(root: cache_root),
      )

      root = MilkTea::PackageLock.load(app_root, source_resolver:)
      dependency_node = root.edges.fetch(0).node

      assert_equal :registry, dependency_node.source.kind
      assert_equal File.expand_path(registry_root), dependency_node.source.local_root
      assert_equal File.expand_path(registry_root), dependency_node.manifest.root_dir
    end
  end

  def test_load_rejects_unmaterialized_cache_backed_sources
    Dir.mktmpdir("milk-tea-package-lock-missing-cache-root") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      app_src_dir = File.join(app_root, "src")
      cache_root = File.join(dir, "cache")
      registry_root = File.join(cache_root, "registry", "teefan.ui@1.2.3")

      FileUtils.mkdir_p(app_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"
      TOML

      File.write(File.join(app_root, "package.lock"), <<~LOCK)
        schema_version = 1
        root_package = "snake_duel"

        [[package]]
        name = "snake_duel"
        kind = "application"
        version = "0.1.0"
        source_kind = "path"
        source_path = #{app_root.inspect}
        manifest_path = #{File.join(app_root, "package.toml").inspect}
        source_root = #{app_src_dir.inspect}
        dependencies = ["teefan.ui"]

        [[package]]
        name = "teefan.ui"
        kind = "library"
        version = "1.2.3"
        source_kind = "registry"
        registry_package = "teefan.ui"
        registry_version = "1.2.3"
        manifest_path = #{File.join(registry_root, "package.toml").inspect}
        source_root = #{File.join(registry_root, "src").inspect}
        dependencies = []
      LOCK

      source_resolver = MilkTea::PackageSourceResolver.new(
        source_cache: MilkTea::PackageSourceCache.new(root: cache_root),
      )

      error = assert_raises(MilkTea::PackageLockError) do
        MilkTea::PackageLock.load(app_root, source_resolver:)
      end

      assert_match(/not materialized in the source cache/, error.message)
      assert_match(/registry/, error.message)
      assert_match(/package\.toml/, error.message)
    end
  end

  def test_load_uses_materialized_manifest_metadata_instead_of_lockfile_paths
    Dir.mktmpdir("milk-tea-package-lock-materialized-manifest") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      app_src_dir = File.join(app_root, "src")
      cache_root = File.join(dir, "cache")
      registry_root = File.join(cache_root, "registry", "teefan.ui@1.2.3")
      bogus_manifest_path = File.join(dir, "bogus", "package.toml")
      bogus_source_root = File.join(dir, "bogus", "src")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(File.join(registry_root, "src"))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"
      TOML

      File.write(File.join(registry_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(app_root, "package.lock"), <<~LOCK)
        schema_version = 1
        root_package = "snake_duel"

        [[package]]
        name = "snake_duel"
        kind = "application"
        version = "0.1.0"
        source_kind = "path"
        source_path = #{app_root.inspect}
        manifest_path = #{File.join(app_root, "package.toml").inspect}
        source_root = #{app_src_dir.inspect}
        dependencies = ["teefan.ui"]

        [[package]]
        name = "teefan.ui"
        kind = "library"
        version = "1.2.3"
        source_kind = "registry"
        registry_package = "teefan.ui"
        registry_version = "1.2.3"
        manifest_path = #{bogus_manifest_path.inspect}
        source_root = #{bogus_source_root.inspect}
        dependencies = []
      LOCK

      source_resolver = MilkTea::PackageSourceResolver.new(
        source_cache: MilkTea::PackageSourceCache.new(root: cache_root),
      )

      root = MilkTea::PackageLock.load(app_root, source_resolver:)
      dependency_node = root.edges.fetch(0).node

      assert_equal File.expand_path(File.join(registry_root, "package.toml")), dependency_node.manifest.manifest_path
      assert_equal File.expand_path(File.join(registry_root, "src")), dependency_node.manifest.source_root
      refute_equal File.expand_path(bogus_manifest_path), dependency_node.manifest.manifest_path
      refute_equal File.expand_path(bogus_source_root), dependency_node.manifest.source_root
    end
  end
end
