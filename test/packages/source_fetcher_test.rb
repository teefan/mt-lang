# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaPackageSourceFetcherTest < Minitest::Test
  def test_fetch_locked_sources_materializes_git_package
    git = ENV.fetch("GIT", "git")
    skip "git not available: #{git}" unless executable_available?(git)

    Dir.mktmpdir("milk-tea-package-source-fetcher") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      cache_root = File.join(dir, "cache")
      origin_root = File.join(dir, "origin-ui")

      FileUtils.mkdir_p(app_root)
      FileUtils.mkdir_p(origin_root)

      run_git!(git:, dir: origin_root, args: ["init", "--initial-branch=main"])
      File.write(File.join(origin_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        kind = "library"
      TOML
      run_git!(git:, dir: origin_root, args: ["add", "."])
      run_git!(git:, dir: origin_root, args: ["commit", "-m", "initial"])

      revision = capture_git(git:, dir: origin_root, args: ["rev-parse", "HEAD"])
      cache = MilkTea::PackageSourceCache.new(root: cache_root)
      identity = MilkTea::PackageSourceResolver::GitIdentity.new(url: origin_root, revision:)
      manifest_path = cache.manifest_path_for(identity)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
      TOML
      File.write(File.join(app_root, "package.lock"), <<~LOCK)
        schema_version = 1
        root_package = "snake_duel"

        [[package]]
        name = "snake_duel"
        kind = "application"
        source_kind = "path"
        source_path = #{app_root.inspect}
        manifest_path = #{File.join(app_root, "package.toml").inspect}
        source_root = #{app_root.inspect}
        dependencies = ["teefan.ui"]

        [[package]]
        name = "teefan.ui"
        kind = "library"
        source_kind = "git"
        git_url = #{origin_root.inspect}
        git_rev = #{revision.inspect}
        manifest_path = #{manifest_path.inspect}
        source_root = #{File.dirname(manifest_path).inspect}
        dependencies = []
      LOCK

      fetcher = MilkTea::PackageSourceFetcher.new(
        source_cache: cache,
        source_resolver: MilkTea::PackageSourceResolver.new(source_cache: cache),
      )

      results = fetcher.fetch_locked_sources(app_root)

      assert_equal 1, results.length
      result = results.fetch(0)
      assert_equal "teefan.ui", result.package_name
      assert_equal :materialized, result.status
      assert_equal File.expand_path(File.dirname(manifest_path)), result.path
      assert File.file?(manifest_path)
    end
  end

  def test_fetch_locked_sources_materializes_registry_package
    Dir.mktmpdir("milk-tea-package-source-fetcher-registry") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      cache_root = File.join(dir, "cache")
      registry_root = File.join(dir, "registry")
      published_root = File.join(dir, "published-ui")
      cache = MilkTea::PackageSourceCache.new(root: cache_root)
      registry_store = MilkTea::PackageRegistryStore.new(root: registry_root)
      identity = MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "1.2.3")

      FileUtils.mkdir_p(app_root)
      FileUtils.mkdir_p(File.join(published_root, "src", "teefan", "ui"))
      File.write(File.join(published_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML
      File.write(File.join(published_root, "src", "teefan", "ui", "layout.mt"), <<~MT)
        module teefan.ui.layout
      MT
      registry_store.publish(published_root)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
      TOML
      File.write(File.join(app_root, "package.lock"), <<~LOCK)
        schema_version = 1
        root_package = "snake_duel"

        [[package]]
        name = "snake_duel"
        kind = "application"
        source_kind = "path"
        source_path = #{app_root.inspect}
        manifest_path = #{File.join(app_root, "package.toml").inspect}
        source_root = #{app_root.inspect}
        dependencies = ["teefan.ui"]

        [[package]]
        name = "teefan.ui"
        kind = "library"
        source_kind = "registry"
        registry_package = "teefan.ui"
        registry_version = "1.2.3"
        manifest_path = #{cache.manifest_path_for(identity).inspect}
        source_root = #{cache.materialized_root_for(identity).inspect}
        dependencies = []
      LOCK

      fetcher = MilkTea::PackageSourceFetcher.new(
        source_cache: cache,
        source_resolver: MilkTea::PackageSourceResolver.new(source_cache: cache),
        registry_store:,
      )

      results = fetcher.fetch_locked_sources(app_root)

      assert_equal 1, results.length
      result = results.fetch(0)
      assert_equal "teefan.ui", result.package_name
      assert_equal :materialized, result.status
      assert_equal File.expand_path(cache.materialized_root_for(identity)), result.path
      assert File.file?(cache.manifest_path_for(identity))
    end
  end

  def test_fetch_locked_sources_syncs_registry_package_from_upstream_store_when_local_registry_is_empty
    Dir.mktmpdir("milk-tea-package-source-fetcher-upstream-registry") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      cache_root = File.join(dir, "cache")
      registry_root = File.join(dir, "registry")
      upstream_root = File.join(dir, "upstream-registry")
      published_root = File.join(dir, "published-ui")
      cache = MilkTea::PackageSourceCache.new(root: cache_root)
      registry_store = MilkTea::PackageRegistryStore.new(root: registry_root, upstream_root: upstream_root)
      identity = MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "1.2.3")

      FileUtils.mkdir_p(app_root)
      FileUtils.mkdir_p(File.join(published_root, "src", "teefan", "ui"))
      File.write(File.join(published_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML
      File.write(File.join(published_root, "src", "teefan", "ui", "layout.mt"), <<~MT)
        module teefan.ui.layout
      MT
      registry_store.publish(published_root, target: :upstream)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
      TOML
      File.write(File.join(app_root, "package.lock"), <<~LOCK)
        schema_version = 1
        root_package = "snake_duel"

        [[package]]
        name = "snake_duel"
        kind = "application"
        source_kind = "path"
        source_path = #{app_root.inspect}
        manifest_path = #{File.join(app_root, "package.toml").inspect}
        source_root = #{app_root.inspect}
        dependencies = ["teefan.ui"]

        [[package]]
        name = "teefan.ui"
        kind = "library"
        source_kind = "registry"
        registry_package = "teefan.ui"
        registry_version = "1.2.3"
        manifest_path = #{cache.manifest_path_for(identity).inspect}
        source_root = #{cache.materialized_root_for(identity).inspect}
        dependencies = []
      LOCK

      fetcher = MilkTea::PackageSourceFetcher.new(
        source_cache: cache,
        source_resolver: MilkTea::PackageSourceResolver.new(source_cache: cache),
        registry_store:,
      )

      results = fetcher.fetch_locked_sources(app_root)

      assert_equal 1, results.length
      result = results.fetch(0)
      assert_equal "teefan.ui", result.package_name
      assert_equal :materialized, result.status
      assert_equal File.expand_path(cache.materialized_root_for(identity)), result.path
      assert File.file?(cache.manifest_path_for(identity))
      assert registry_store.published?(identity)
    end
  end

  def test_fetch_locked_sources_rejects_duplicate_package_entries
    Dir.mktmpdir("milk-tea-package-source-fetcher-duplicate") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      cache_root = File.join(dir, "cache")
      cache = MilkTea::PackageSourceCache.new(root: cache_root)
      identity = MilkTea::PackageSourceResolver::RegistryIdentity.new(package_name: "teefan.ui", version: "1.2.3")

      FileUtils.mkdir_p(app_root)
      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
      TOML
      File.write(File.join(app_root, "package.lock"), <<~LOCK)
        schema_version = 1
        root_package = "snake_duel"

        [[package]]
        name = "snake_duel"
        kind = "application"
        source_kind = "path"
        source_path = #{app_root.inspect}
        manifest_path = #{File.join(app_root, "package.toml").inspect}
        source_root = #{app_root.inspect}
        dependencies = ["teefan.ui"]

        [[package]]
        name = "teefan.ui"
        kind = "library"
        source_kind = "registry"
        registry_package = "teefan.ui"
        registry_version = "1.2.3"
        manifest_path = #{cache.manifest_path_for(identity).inspect}
        source_root = #{cache.materialized_root_for(identity).inspect}
        dependencies = []

        [[package]]
        name = "teefan.ui"
        kind = "library"
        source_kind = "registry"
        registry_package = "teefan.ui"
        registry_version = "1.2.3"
        manifest_path = #{cache.manifest_path_for(identity).inspect}
        source_root = #{cache.materialized_root_for(identity).inspect}
        dependencies = []
      LOCK

      fetcher = MilkTea::PackageSourceFetcher.new(
        source_cache: cache,
        source_resolver: MilkTea::PackageSourceResolver.new(source_cache: cache),
        registry_store: MilkTea::PackageRegistryStore.new(root: File.join(dir, "registry")),
      )

      error = assert_raises(MilkTea::PackageSourceFetcherError) do
        fetcher.fetch_locked_sources(app_root)
      end

      assert_match(/duplicate package instance teefan\.ui/, error.message)
    end
  end

  private

  def executable_available?(program)
    return File.executable?(program) if program.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, program)
      File.file?(candidate) && File.executable?(candidate)
    end
  end

  def capture_git(git:, dir:, args:)
    stdout, stderr, status = Open3.capture3(git_env, git, "-C", dir, *args)
    assert status.success?, stderr

    stdout.strip
  end

  def run_git!(git:, dir:, args:)
    stdout, stderr, status = Open3.capture3(git_env, git, "-C", dir, *args)
    assert status.success?, [stdout, stderr].reject(&:empty?).join
  end

  def git_env
    {
      "GIT_AUTHOR_NAME" => "Milk Tea Tests",
      "GIT_AUTHOR_EMAIL" => "tests@example.com",
      "GIT_COMMITTER_NAME" => "Milk Tea Tests",
      "GIT_COMMITTER_EMAIL" => "tests@example.com",
    }
  end
end
