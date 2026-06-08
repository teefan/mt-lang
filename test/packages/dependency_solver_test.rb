# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaPackageDependencySolverTest < Minitest::Test
  def test_solve_resolves_single_exact_registry_dependency
    Dir.mktmpdir("milk-tea-dependency-solver-exact") do |dir|
      app_root = File.join(dir, "apps", "app")
      registry_root = File.join(dir, "registry")
      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(registry_root, "packages", "teefan.ui", "1.2.3", "src"))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"

        [dependencies]
        "teefan.ui" = "1.2.3"
      TOML

      File.write(File.join(registry_root, "packages", "teefan.ui", "1.2.3", "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.2.3"
        kind = "library"
        source_root = "src"
      TOML

      cache = MilkTea::PackageSourceCache.new(root: File.join(dir, "cache"))
      registry_store = MilkTea::PackageRegistryStore.new(root: registry_root)
      source_fetcher = MilkTea::PackageSourceFetcher.new(
        source_cache: cache,
        source_resolver: MilkTea::PackageSourceResolver.new(source_cache: cache),
        registry_store:,
      )
      provider = MilkTea::PackageRegistryMetadataProvider.new(registry_store:)
      source_resolver = MilkTea::PackageSourceResolver.new(
        source_cache: cache,
        remote_resolution: :materialize,
        source_fetcher:,
      )

      solver = MilkTea::PackageDependencySolver.new(
        source_resolver:,
        registry_metadata_provider: provider,
      )

      solution = solver.solve(app_root)

      assert_equal 0, solution.registry_versions.length
    end
  end

  def test_solve_resolves_ranged_registry_dependency_with_multiple_candidates
    Dir.mktmpdir("milk-tea-dependency-solver-range") do |dir|
      app_root = File.join(dir, "apps", "app")
      registry_root = File.join(dir, "registry")
      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(registry_root, "packages", "teefan.ui", "1.2.0", "src"))
      FileUtils.mkdir_p(File.join(registry_root, "packages", "teefan.ui", "1.3.0", "src"))
      FileUtils.mkdir_p(File.join(registry_root, "packages", "teefan.ui", "2.0.0", "src"))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"

        [dependencies]
        "teefan.ui" = "^1.2.0"
      TOML

      [["1.2.0", []], ["1.3.0", []], ["2.0.0", []]].each do |version, _deps|
        File.write(File.join(registry_root, "packages", "teefan.ui", version, "package.toml"), <<~TOML)
          [package]
          name = "teefan.ui"
          version = "#{version}"
          kind = "library"
          source_root = "src"
        TOML
      end

      cache = MilkTea::PackageSourceCache.new(root: File.join(dir, "cache"))
      registry_store = MilkTea::PackageRegistryStore.new(root: registry_root)
      source_fetcher = MilkTea::PackageSourceFetcher.new(
        source_cache: cache,
        source_resolver: MilkTea::PackageSourceResolver.new(source_cache: cache),
        registry_store:,
      )
      provider = MilkTea::PackageRegistryMetadataProvider.new(registry_store:)
      source_resolver = MilkTea::PackageSourceResolver.new(
        source_cache: cache,
        remote_resolution: :materialize,
        source_fetcher:,
      )

      solver = MilkTea::PackageDependencySolver.new(
        source_resolver:,
        registry_metadata_provider: provider,
      )

      solution = solver.solve(app_root)

      assert_match(/\A1\./, solution.registry_versions.values.first)
    end
  end

  def test_solve_rejects_ranged_dependency_with_no_matching_version
    Dir.mktmpdir("milk-tea-dependency-solver-no-match") do |dir|
      app_root = File.join(dir, "apps", "app")
      registry_root = File.join(dir, "registry")
      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(registry_root, "packages", "teefan.ui", "1.0.0", "src"))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"

        [dependencies]
        "teefan.ui" = "^2.0.0"
      TOML

      File.write(File.join(registry_root, "packages", "teefan.ui", "1.0.0", "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "1.0.0"
        kind = "library"
        source_root = "src"
      TOML

      cache = MilkTea::PackageSourceCache.new(root: File.join(dir, "cache"))
      registry_store = MilkTea::PackageRegistryStore.new(root: registry_root)
      source_fetcher = MilkTea::PackageSourceFetcher.new(
        source_cache: cache,
        source_resolver: MilkTea::PackageSourceResolver.new(source_cache: cache),
        registry_store:,
      )
      provider = MilkTea::PackageRegistryMetadataProvider.new(registry_store:)
      source_resolver = MilkTea::PackageSourceResolver.new(
        source_cache: cache,
        remote_resolution: :materialize,
        source_fetcher:,
      )

      solver = MilkTea::PackageDependencySolver.new(
        source_resolver:,
        registry_metadata_provider: provider,
      )

      error = assert_raises(MilkTea::PackageDependencySolverError) do
        solver.solve(app_root)
      end

      assert_match(/no registry version/, error.message)
    end
  end

  def test_solve_handles_diamond_dependency_without_error
    Dir.mktmpdir("milk-tea-dependency-solver-diamond") do |dir|
      app_root = File.join(dir, "apps", "app")
      registry_root = File.join(dir, "registry")
      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(registry_root, "packages", "a", "1.0.0", "src"))
      FileUtils.mkdir_p(File.join(registry_root, "packages", "b", "1.0.0", "src"))
      FileUtils.mkdir_p(File.join(registry_root, "packages", "c", "1.0.0", "src"))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"

        [dependencies]
        "a" = "1.0.0"
        "b" = "1.0.0"
      TOML

      File.write(File.join(registry_root, "packages", "a", "1.0.0", "package.toml"), <<~TOML)
        [package]
        name = "a"
        version = "1.0.0"
        kind = "library"
        source_root = "src"

        [dependencies]
        "c" = "1.0.0"
      TOML

      File.write(File.join(registry_root, "packages", "b", "1.0.0", "package.toml"), <<~TOML)
        [package]
        name = "b"
        version = "1.0.0"
        kind = "library"
        source_root = "src"

        [dependencies]
        "c" = "1.0.0"
      TOML

      File.write(File.join(registry_root, "packages", "c", "1.0.0", "package.toml"), <<~TOML)
        [package]
        name = "c"
        version = "1.0.0"
        kind = "library"
        source_root = "src"
      TOML

      cache = MilkTea::PackageSourceCache.new(root: File.join(dir, "cache"))
      registry_store = MilkTea::PackageRegistryStore.new(root: registry_root)
      source_fetcher = MilkTea::PackageSourceFetcher.new(
        source_cache: cache,
        source_resolver: MilkTea::PackageSourceResolver.new(source_cache: cache),
        registry_store:,
      )
      provider = MilkTea::PackageRegistryMetadataProvider.new(registry_store:)
      source_resolver = MilkTea::PackageSourceResolver.new(
        source_cache: cache,
        remote_resolution: :materialize,
        source_fetcher:,
      )

      solver = MilkTea::PackageDependencySolver.new(
        source_resolver:,
        registry_metadata_provider: provider,
      )

      solution = solver.solve(app_root)

      assert_equal 0, solution.registry_versions.length
    end
  end

  def test_solve_respects_locked_registry_versions
    Dir.mktmpdir("milk-tea-dependency-solver-locked") do |dir|
      app_root = File.join(dir, "apps", "app")
      registry_root = File.join(dir, "registry")
      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(registry_root, "packages", "teefan.ui", "1.2.0", "src"))
      FileUtils.mkdir_p(File.join(registry_root, "packages", "teefan.ui", "1.3.0", "src"))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"

        [dependencies]
        "teefan.ui" = "^1.2.0"
      TOML

      [["1.2.0", []], ["1.3.0", []]].each do |version, _deps|
        File.write(File.join(registry_root, "packages", "teefan.ui", version, "package.toml"), <<~TOML)
          [package]
          name = "teefan.ui"
          version = "#{version}"
          kind = "library"
          source_root = "src"
        TOML
      end

      cache = MilkTea::PackageSourceCache.new(root: File.join(dir, "cache"))
      registry_store = MilkTea::PackageRegistryStore.new(root: registry_root)
      source_fetcher = MilkTea::PackageSourceFetcher.new(
        source_cache: cache,
        source_resolver: MilkTea::PackageSourceResolver.new(source_cache: cache),
        registry_store:,
      )
      provider = MilkTea::PackageRegistryMetadataProvider.new(registry_store:)
      source_resolver = MilkTea::PackageSourceResolver.new(
        source_cache: cache,
        remote_resolution: :materialize,
        source_fetcher:,
      )

      locked_versions = {
        ["path:#{File.expand_path(app_root)}", "teefan.ui"] => "1.2.0",
      }

      solver = MilkTea::PackageDependencySolver.new(
        source_resolver:,
        registry_metadata_provider: provider,
        locked_registry_versions: locked_versions,
      )

      solution = solver.solve(app_root)

      assert_equal "1.2.0", solution.registry_versions.values.first
    end
  end

  def test_solve_resolves_path_dependency_in_registry_solver_context
    Dir.mktmpdir("milk-tea-dependency-solver-path-mixed") do |dir|
      app_root = File.join(dir, "apps", "app")
      lib_root = File.join(dir, "libs", "lib")
      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(lib_root, "src"))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"

        [dependencies]
        "lib" = { path = "../../libs/lib" }
      TOML

      File.write(File.join(lib_root, "package.toml"), <<~TOML)
        [package]
        name = "lib"
        kind = "library"
        source_root = "src"
      TOML

      source_resolver = MilkTea::PackageSourceResolver.new
      provider = MilkTea::PackageRegistryMetadataProvider.new

      solver = MilkTea::PackageDependencySolver.new(
        source_resolver:,
        registry_metadata_provider: provider,
      )

      solution = solver.solve(app_root)

      assert_equal 0, solution.registry_versions.length
    end
  end

  def test_solve_accepts_manifest_data_view_directly
    Dir.mktmpdir("milk-tea-dependency-solver-manifest") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))

      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"
      TOML

      manifest = MilkTea::PackageManifest.load(dir)
      source_resolver = MilkTea::PackageSourceResolver.new
      provider = MilkTea::PackageRegistryMetadataProvider.new

      solver = MilkTea::PackageDependencySolver.new(
        source_resolver:,
        registry_metadata_provider: provider,
      )

      solution = solver.solve(manifest)

      assert_equal 0, solution.registry_versions.length
    end
  end
end
