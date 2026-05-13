# frozen_string_literal: true

require_relative "../test_helper"

class MilkTeaPackageSourceCacheTest < Minitest::Test
  def test_default_root_prefers_xdg_cache_home
    root = MilkTea::PackageSourceCache.default_root(
      env: { "XDG_CACHE_HOME" => "/tmp/mt-xdg-cache" },
      home: "/tmp/home",
    )

    assert_equal File.expand_path("/tmp/mt-xdg-cache/milk_tea/package_sources"), root
  end

  def test_default_root_falls_back_to_home_cache_directory
    root = MilkTea::PackageSourceCache.default_root(
      env: {},
      home: "/tmp/home",
    )

    assert_equal File.expand_path("/tmp/home/.cache/milk_tea/package_sources"), root
  end

  def test_path_for_registry_identity_uses_cache_key_segments
    cache = MilkTea::PackageSourceCache.new(root: "/tmp/mt-package-cache")
    identity = MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "1.2.3")

    path = cache.path_for(identity)

    assert_equal File.expand_path("/tmp/mt-package-cache/registry/teefan.ui@1.2.3"), path
  end

  def test_path_for_git_identity_uses_digest_cache_key
    cache = MilkTea::PackageSourceCache.new(root: "/tmp/mt-package-cache")
    identity = MilkTea::PackageSourceResolver::GitIdentity.new(
      url: "https://example.invalid/teefan/ui.git",
      revision: "deadbeef",
      subdir: "packages/ui",
    )

    path = cache.path_for(identity)

    assert_match(%r{\A#{Regexp.escape(File.expand_path('/tmp/mt-package-cache'))}/git/[0-9a-f]{64}\z}, path)
  end

  def test_materialized_root_for_registry_identity_matches_cache_path
    cache = MilkTea::PackageSourceCache.new(root: "/tmp/mt-package-cache")
    identity = MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "1.2.3")

    path = cache.materialized_root_for(identity)

    assert_equal File.expand_path("/tmp/mt-package-cache/registry/teefan.ui@1.2.3"), path
  end

  def test_manifest_path_for_registry_identity_points_to_package_toml
    cache = MilkTea::PackageSourceCache.new(root: "/tmp/mt-package-cache")
    identity = MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "1.2.3")

    path = cache.manifest_path_for(identity)

    assert_equal File.expand_path("/tmp/mt-package-cache/registry/teefan.ui@1.2.3/package.toml"), path
  end

  def test_materialized_root_for_git_identity_appends_subdir
    cache = MilkTea::PackageSourceCache.new(root: "/tmp/mt-package-cache")
    identity = MilkTea::PackageSourceResolver::GitIdentity.new(
      url: "https://example.invalid/teefan/ui.git",
      revision: "deadbeef",
      subdir: "packages/ui",
    )

    path = cache.materialized_root_for(identity)

    assert_match(%r{\A#{Regexp.escape(File.expand_path('/tmp/mt-package-cache'))}/git/[0-9a-f]{64}/packages/ui\z}, path)
  end

  def test_materialized_reports_cache_state_from_manifest_path
    Dir.mktmpdir("milk-tea-package-source-cache-materialized") do |dir|
      cache = MilkTea::PackageSourceCache.new(root: dir)
      identity = MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "1.2.3")
      manifest_path = cache.manifest_path_for(identity)

      refute cache.materialized?(identity)

      FileUtils.mkdir_p(File.dirname(manifest_path))
      File.write(manifest_path, "[package]\nname = \"teefan.ui\"\n")

      assert cache.materialized?(identity)
    end
  end

  def test_path_for_rejects_non_cacheable_path_identity
    cache = MilkTea::PackageSourceCache.new(root: "/tmp/mt-package-cache")
    identity = MilkTea::PackageSourceResolver::PathIdentity.new("/tmp/worktree/ui")

    error = assert_raises(MilkTea::PackageSourceCacheError) do
      cache.path_for(identity)
    end

    assert_match(/does not use the shared source cache/, error.message)
    assert_match(/path/, error.message)
  end

  def test_materialized_root_for_rejects_non_cacheable_path_identity
    cache = MilkTea::PackageSourceCache.new(root: "/tmp/mt-package-cache")
    identity = MilkTea::PackageSourceResolver::PathIdentity.new("/tmp/worktree/ui")

    error = assert_raises(MilkTea::PackageSourceCacheError) do
      cache.materialized_root_for(identity)
    end

    assert_match(/does not use the shared source cache/, error.message)
    assert_match(/path/, error.message)
  end

  def test_manifest_path_for_rejects_non_cacheable_path_identity
    cache = MilkTea::PackageSourceCache.new(root: "/tmp/mt-package-cache")
    identity = MilkTea::PackageSourceResolver::PathIdentity.new("/tmp/worktree/ui")

    error = assert_raises(MilkTea::PackageSourceCacheError) do
      cache.manifest_path_for(identity)
    end

    assert_match(/does not use the shared source cache/, error.message)
    assert_match(/path/, error.message)
  end
end
