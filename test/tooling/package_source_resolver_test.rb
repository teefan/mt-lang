# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaPackageSourceResolverTest < Minitest::Test
  def test_resolve_loads_path_dependency_manifest_and_source_metadata
    Dir.mktmpdir("milk-tea-package-source-resolver") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      FileUtils.mkdir_p(app_root)
      FileUtils.mkdir_p(ui_root)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        kind = "library"
      TOML

      root_manifest = MilkTea::PackageManifest.load(app_root)
      dependency = root_manifest.dependencies.fetch(0)

      resolved_package = MilkTea::PackageSourceResolver.new.resolve(dependency, parent_manifest: root_manifest)
      resolved_manifest = resolved_package.manifest
      resolved_source = resolved_package.source

      assert_equal "teefan.ui", resolved_manifest.package_name
      assert_equal File.expand_path(ui_root), resolved_manifest.root_dir
      assert_instance_of MilkTea::PackageSourceResolver::PathIdentity, resolved_source.identity
      assert_equal :path, resolved_source.kind
      assert_equal File.expand_path(ui_root), resolved_source.local_root
      assert_equal({ "source_path" => File.expand_path(ui_root) }, resolved_source.lock_attributes)
      assert_nil resolved_source.cache_key
      refute resolved_source.cacheable?
    end
  end

  def test_resolve_rejects_registry_dependency_without_explicit_remote_resolution
    Dir.mktmpdir("milk-tea-package-source-resolver-unsupported") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      FileUtils.mkdir_p(app_root)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
      TOML

      root_manifest = MilkTea::PackageManifest.load(app_root)
      dependency = MilkTea::PackageManifest::DependencyView.new("teefan.ui", "0.3.0", nil, nil, nil, nil)

      error = assert_raises(MilkTea::PackageSourceResolverError) do
        MilkTea::PackageSourceResolver.new.resolve(dependency, parent_manifest: root_manifest)
      end

      assert_match(/uses registry resolution/, error.message)
      assert_match(/--locked or --frozen/, error.message)
      assert_match(/teefan\.ui/, error.message)
    end
  end

  def test_resolve_rejects_git_dependency_without_explicit_git_resolution
    Dir.mktmpdir("milk-tea-package-source-resolver-git-live") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      FileUtils.mkdir_p(app_root)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
      TOML

      root_manifest = MilkTea::PackageManifest.load(app_root)
      dependency = MilkTea::PackageManifest::DependencyView.new(
        "teefan.ui",
        nil,
        "https://example.invalid/teefan/ui.git",
        "deadbeef",
        nil,
        nil,
      )

      error = assert_raises(MilkTea::PackageSourceResolverError) do
        MilkTea::PackageSourceResolver.new.resolve(dependency, parent_manifest: root_manifest)
      end

      assert_match(/uses git resolution/, error.message)
      assert_match(/--locked or --frozen/, error.message)
    end
  end

  def test_resolve_uses_materialized_cache_for_registry_dependency_when_remote_resolution_is_cache
    Dir.mktmpdir("milk-tea-package-source-resolver-registry-cache") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      cache = MilkTea::PackageSourceCache.new(root: File.join(dir, "cache"))
      identity = MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "1.2.3")
      manifest_path = cache.manifest_path_for(identity)

      FileUtils.mkdir_p(app_root)
      FileUtils.mkdir_p(File.dirname(manifest_path))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
      TOML

      File.write(manifest_path, <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
      TOML

      root_manifest = MilkTea::PackageManifest.load(app_root)
      dependency = MilkTea::PackageManifest::DependencyView.new("teefan.ui", "1.2.3", nil, nil, nil, nil)

      resolved_package = MilkTea::PackageSourceResolver.new(
        source_cache: cache,
        remote_resolution: :cache,
      ).resolve(dependency, parent_manifest: root_manifest)

      assert_equal "teefan.ui", resolved_package.manifest.package_name
      assert_equal :registry, resolved_package.source.kind
      assert_equal File.expand_path(File.dirname(manifest_path)), resolved_package.source.local_root
    end
  end

  def test_resolve_uses_materialized_cache_for_git_dependency_when_remote_resolution_is_cache
    Dir.mktmpdir("milk-tea-package-source-resolver-git-cache") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      cache = MilkTea::PackageSourceCache.new(root: File.join(dir, "cache"))
      identity = MilkTea::PackageSourceResolver::GitIdentity.new(
        url: "https://example.invalid/teefan/ui.git",
        revision: "deadbeef",
        subdir: "packages/ui",
      )
      manifest_path = cache.manifest_path_for(identity)

      FileUtils.mkdir_p(app_root)
      FileUtils.mkdir_p(File.dirname(manifest_path))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
      TOML

      File.write(manifest_path, <<~TOML)
        [package]
        name = "teefan.ui"
        kind = "library"
      TOML

      root_manifest = MilkTea::PackageManifest.load(app_root)
      dependency = MilkTea::PackageManifest::DependencyView.new(
        "teefan.ui",
        nil,
        identity.url,
        identity.revision,
        identity.subdir,
        nil,
      )

      resolved_package = MilkTea::PackageSourceResolver.new(
        source_cache: cache,
        remote_resolution: :cache,
      ).resolve(dependency, parent_manifest: root_manifest)

      assert_equal "teefan.ui", resolved_package.manifest.package_name
      assert_equal :git, resolved_package.source.kind
      assert_equal File.expand_path(File.dirname(manifest_path)), resolved_package.source.local_root
    end
  end

  def test_source_from_lock_builds_path_source_metadata
    source = MilkTea::PackageSourceResolver.new.source_from_lock({
      "source_kind" => "path",
      "source_path" => "/tmp/example-ui",
    }, "/tmp/package.lock")

    assert_equal :path, source.kind
    assert_equal File.expand_path("/tmp/example-ui"), source.local_root
    assert_equal({ "source_path" => File.expand_path("/tmp/example-ui") }, source.lock_attributes)
  end

  def test_identity_from_lock_builds_registry_identity_with_stable_cache_key
    identity = MilkTea::PackageSourceResolver.new.identity_from_lock({
      "source_kind" => "registry",
      "registry_package" => "teefan.ui",
      "registry_version" => "1.2.3",
    }, "/tmp/package.lock")

    assert_instance_of MilkTea::PackageSourceResolver::RegistryIdentity, identity
    assert_equal :registry, identity.kind
    assert_equal({
      "registry_package" => "teefan.ui",
      "registry_version" => "1.2.3",
    }, identity.lock_attributes)
    assert_equal "registry/teefan.ui@1.2.3", identity.cache_key
    assert identity.cacheable?
  end

  def test_identity_from_lock_builds_git_identity_with_stable_cache_key
    identity = MilkTea::PackageSourceResolver.new.identity_from_lock({
      "source_kind" => "git",
      "git_url" => "https://example.invalid/teefan/ui.git",
      "git_rev" => "deadbeef",
      "git_subdir" => "packages/ui",
    }, "/tmp/package.lock")

    assert_instance_of MilkTea::PackageSourceResolver::GitIdentity, identity
    assert_equal :git, identity.kind
    assert_equal({
      "git_url" => "https://example.invalid/teefan/ui.git",
      "git_rev" => "deadbeef",
      "git_subdir" => "packages/ui",
    }, identity.lock_attributes)
    assert_match(%r{\Agit/[0-9a-f]{64}\z}, identity.cache_key)
    assert identity.cacheable?
  end

  def test_source_from_lock_builds_registry_source_with_materialized_cache_root
    Dir.mktmpdir("milk-tea-package-source-resolver-registry") do |dir|
      cache = MilkTea::PackageSourceCache.new(root: dir)
      manifest_path = cache.manifest_path_for(
        MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "1.2.3"),
      )
      FileUtils.mkdir_p(File.dirname(manifest_path))
      File.write(manifest_path, "[package]\nname = \"teefan.ui\"\n")

      resolver = MilkTea::PackageSourceResolver.new(source_cache: cache)

      source = resolver.source_from_lock({
        "source_kind" => "registry",
        "registry_package" => "teefan.ui",
        "registry_version" => "1.2.3",
      }, "/tmp/package.lock")

      assert_equal :registry, source.kind
      assert_equal File.expand_path(File.dirname(manifest_path)), source.local_root
    end
  end

  def test_source_from_lock_builds_git_source_with_materialized_cache_root
    Dir.mktmpdir("milk-tea-package-source-resolver-git") do |dir|
      cache = MilkTea::PackageSourceCache.new(root: dir)
      manifest_path = cache.manifest_path_for(
        MilkTea::PackageSourceResolver::GitIdentity.new(
          url: "https://example.invalid/teefan/ui.git",
          revision: "deadbeef",
          subdir: "packages/ui",
        ),
      )
      FileUtils.mkdir_p(File.dirname(manifest_path))
      File.write(manifest_path, "[package]\nname = \"teefan.ui\"\n")

      resolver = MilkTea::PackageSourceResolver.new(source_cache: cache)

      source = resolver.source_from_lock({
        "source_kind" => "git",
        "git_url" => "https://example.invalid/teefan/ui.git",
        "git_rev" => "deadbeef",
        "git_subdir" => "packages/ui",
      }, "/tmp/package.lock")

      assert_equal :git, source.kind
      assert_equal File.expand_path(File.dirname(manifest_path)), source.local_root
    end
  end

  def test_source_from_lock_rejects_unmaterialized_cache_backed_identity
    resolver = MilkTea::PackageSourceResolver.new(
      source_cache: MilkTea::PackageSourceCache.new(root: "/tmp/mt-package-cache"),
    )

    error = assert_raises(MilkTea::PackageSourceResolverError) do
      resolver.source_from_lock({
        "source_kind" => "registry",
        "registry_package" => "teefan.ui",
        "registry_version" => "1.2.3",
      }, "/tmp/package.lock")
    end

    assert_match(/not materialized in the source cache/, error.message)
    assert_match(/registry/, error.message)
    assert_match(/package\.toml/, error.message)
  end
end
