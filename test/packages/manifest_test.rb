# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaPackageManifestTest < Minitest::Test
  def test_load_defaults_package_name_to_snake_case_directory_basename
    Dir.mktmpdir("milk-tea-package-manifest-default-name") do |dir|
      project_root = File.join(dir, "MyProject")
      FileUtils.mkdir_p(File.join(project_root, "src"))
      File.write(File.join(project_root, "src", "main.mt"), <<~MT)
      MT
      File.write(File.join(project_root, "package.toml"), <<~TOML)
        [package]
        version = "0.1.0"

        [build]
        entry = "src/main.mt"
      TOML

      manifest = MilkTea::PackageManifest.load(project_root)

      assert_equal "my_project", manifest.package_name
      assert_equal File.expand_path(File.join(project_root, "src")), manifest.source_root
    end
  end

  def test_load_defaults_source_root_to_package_root_when_src_directory_is_absent
    Dir.mktmpdir("milk-tea-package-manifest-default-root") do |dir|
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "flat_app"
      TOML

      manifest = MilkTea::PackageManifest.load(dir)

      assert_equal File.expand_path(dir), manifest.source_root
    end
  end

  def test_load_parses_exact_registry_dependency_as_exact_requirement
    Dir.mktmpdir("milk-tea-package-manifest") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [dependencies]
        "teefan.ui" = "1.2.3"
      TOML

      manifest = MilkTea::PackageManifest.load(dir)
      dependency = manifest.dependencies.fetch(0)

      assert_equal "teefan.ui", dependency.name
      assert dependency.registry?
      assert dependency.exact_registry_version?
      assert_equal "1.2.3", dependency.version
      assert_equal "1.2.3", dependency.version_req.exact_version.to_s
    end
  end

  def test_load_parses_ranged_registry_dependency_requirement
    Dir.mktmpdir("milk-tea-package-manifest-range") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { version = ">=1.2.3, <2.0.0" }
      TOML

      manifest = MilkTea::PackageManifest.load(dir)
      dependency = manifest.dependencies.fetch(0)

      assert dependency.registry?
      refute dependency.exact_registry_version?
      assert_nil dependency.version
      assert dependency.version_req.matches?("1.5.0")
      refute dependency.version_req.matches?("2.0.0")
    end
  end

  def test_load_rejects_invalid_registry_dependency_requirement
    Dir.mktmpdir("milk-tea-package-manifest-invalid-range") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [dependencies]
        "teefan.ui" = "^banana"
      TOML

      error = assert_raises(MilkTea::PackageManifestError) do
        MilkTea::PackageManifest.load(dir)
      end

      assert_match(/semantic version format/, error.message)
    end
  end

  def test_load_rejects_build_assets_with_duplicate_basenames
    Dir.mktmpdir("milk-tea-package-manifest-assets-collision") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      FileUtils.mkdir_p(File.join(dir, "art", "assets"))
      FileUtils.mkdir_p(File.join(dir, "ui", "assets"))
      File.write(File.join(dir, "src", "main.mt"), "module main\n")
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [build]
        entry = "src/main.mt"
        assets = ["art/assets", "ui/assets"]
      TOML

      error = assert_raises(MilkTea::PackageManifestError) do
        MilkTea::PackageManifest.load(dir)
      end

      assert_match(/build\.assets entries must have unique basenames: assets/, error.message)
    end
  end

  def test_load_parses_git_dependency_with_revision
    Dir.mktmpdir("milk-tea-package-manifest-git") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { git = "https://example.com/ui.git", rev = "deadbeef" }
      TOML

      manifest = MilkTea::PackageManifest.load(dir)
      dependency = manifest.dependencies.fetch(0)

      assert_equal "teefan.ui", dependency.name
      assert dependency.git_dependency?
      assert_equal "https://example.com/ui.git", dependency.git
      assert_equal "deadbeef", dependency.git_rev
      assert_nil dependency.git_subdir
      refute dependency.registry?
    end
  end

  def test_load_parses_git_dependency_with_subdir
    Dir.mktmpdir("milk-tea-package-manifest-git-subdir") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { git = "https://example.com/ui.git", rev = "deadbeef", subdir = "packages/ui" }
      TOML

      manifest = MilkTea::PackageManifest.load(dir)
      dependency = manifest.dependencies.fetch(0)

      assert_equal "packages/ui", dependency.git_subdir
    end
  end

  def test_load_rejects_git_dependency_without_revision
    Dir.mktmpdir("milk-tea-package-manifest-git-no-rev") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { git = "https://example.com/ui.git" }
      TOML

      error = assert_raises(MilkTea::PackageManifestError) do
        MilkTea::PackageManifest.load(dir)
      end

      assert_match(/missing rev/, error.message)
    end
  end

  def test_load_rejects_git_dependency_with_version
    Dir.mktmpdir("milk-tea-package-manifest-git-version") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { git = "https://example.com/ui.git", rev = "deadbeef", version = "1.2.3" }
      TOML

      error = assert_raises(MilkTea::PackageManifestError) do
        MilkTea::PackageManifest.load(dir)
      end

      assert_match(/cannot combine version with git/, error.message)
    end
  end

  def test_load_rejects_subdir_without_git
    Dir.mktmpdir("milk-tea-package-manifest-subdir-no-git") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { subdir = "packages/ui" }
      TOML

      error = assert_raises(MilkTea::PackageManifestError) do
        MilkTea::PackageManifest.load(dir)
      end

      assert_match(/subdir without git/, error.message)
    end
  end

  def test_load_rejects_rev_without_git
    Dir.mktmpdir("milk-tea-package-manifest-rev-no-git") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { rev = "deadbeef" }
      TOML

      error = assert_raises(MilkTea::PackageManifestError) do
        MilkTea::PackageManifest.load(dir)
      end

      assert_match(/rev without git/, error.message)
    end
  end

  def test_load_parses_path_dependency_with_version_constraint
    Dir.mktmpdir("milk-tea-package-manifest-path-version") do |dir|
      app_root = File.join(dir, "app")
      lib_root = File.join(dir, "lib")
      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(lib_root)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"

        [dependencies]
        "lib" = { path = "../lib", version = ">=1.0.0, <2.0.0" }
      TOML

      File.write(File.join(lib_root, "package.toml"), <<~TOML)
        [package]
        name = "lib"
        version = "1.2.0"
        kind = "library"
      TOML

      manifest = MilkTea::PackageManifest.load(app_root)
      dependency = manifest.dependencies.fetch(0)

      assert dependency.path_dependency?
      assert_equal File.expand_path(lib_root), dependency.path
      refute_nil dependency.version_req
      assert_equal ">=1.0.0, <2.0.0", dependency.version_req.to_s
    end
  end

  def test_load_rejects_missing_path_dependency
    Dir.mktmpdir("milk-tea-package-manifest-missing-path") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../nonexistent" }
      TOML

      error = assert_raises(MilkTea::PackageManifestError) do
        MilkTea::PackageManifest.load(dir)
      end

      assert_match(/path not found/, error.message)
    end
  end

  def test_load_rejects_conflicting_path_and_git
    Dir.mktmpdir("milk-tea-package-manifest-path-git-conflict") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../lib", git = "https://example.com/ui.git", rev = "deadbeef" }
      TOML

      error = assert_raises(MilkTea::PackageManifestError) do
        MilkTea::PackageManifest.load(dir)
      end

      assert_match(/must choose exactly one of version, git, or path/, error.message)
    end
  end

  def test_load_rejects_dependency_without_source_declaration
    Dir.mktmpdir("milk-tea-package-manifest-no-source") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { }
      TOML

      error = assert_raises(MilkTea::PackageManifestError) do
        MilkTea::PackageManifest.load(dir)
      end

      assert_match(/must declare version, git, or path/, error.message)
    end
  end

  def test_load_rejects_dependencies_with_invalid_type
    Dir.mktmpdir("milk-tea-package-manifest-deps-type") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [dependencies]
        "teefan.ui" = ["weird"]
      TOML

      error = assert_raises(MilkTea::PackageManifestError) do
        MilkTea::PackageManifest.load(dir)
      end

      assert_match(/unsupported type/, error.message)
    end
  end

  def test_load_rejects_invalid_package_kind
    Dir.mktmpdir("milk-tea-package-manifest-bad-kind") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "app"
        kind = "plugin"
        source_root = "src"
      TOML

      error = assert_raises(MilkTea::PackageManifestError) do
        MilkTea::PackageManifest.load(dir)
      end

      assert_match(/unknown package kind/, error.message)
    end
  end

  def test_load_rejects_invalid_profile
    Dir.mktmpdir("milk-tea-package-manifest-bad-profile") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"

        [profile]
        default = "production"
      TOML

      error = assert_raises(MilkTea::PackageManifestError) do
        MilkTea::PackageManifest.load(dir)
      end

      assert_match(/unknown profile/, error.message)
    end
  end

  def test_load_rejects_invalid_platform
    Dir.mktmpdir("milk-tea-package-manifest-bad-platform") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"

        [platform]
        default = "ps5"
      TOML

      error = assert_raises(MilkTea::PackageManifestError) do
        MilkTea::PackageManifest.load(dir)
      end

      assert_match(/unknown platform/, error.message)
    end
  end

  def test_load_rejects_missing_build_entry
    Dir.mktmpdir("milk-tea-package-manifest-missing-entry") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"

        [build]
        entry = "src/nonexistent.mt"
      TOML

      error = assert_raises(MilkTea::PackageManifestError) do
        MilkTea::PackageManifest.load(dir)
      end

      assert_match(/build\.entry not found/, error.message)
    end
  end

  def test_load_rejects_missing_source_root
    Dir.mktmpdir("milk-tea-package-manifest-missing-src") do |dir|
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "nonexistent"
      TOML

      error = assert_raises(MilkTea::PackageManifestError) do
        MilkTea::PackageManifest.load(dir)
      end

      assert_match(/source_root not found/, error.message)
    end
  end

  def test_load_parses_single_asset_string
    Dir.mktmpdir("milk-tea-package-manifest-single-asset") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      FileUtils.mkdir_p(File.join(dir, "data"))
      File.write(File.join(dir, "src", "main.mt"), "module main\n")
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"

        [build]
        entry = "src/main.mt"
        assets = "data"
      TOML

      manifest = MilkTea::PackageManifest.load(dir)

      assert_equal [File.expand_path(File.join(dir, "data"))], manifest.assets_paths
    end
  end

  def test_load_defaults_kind_to_application
    Dir.mktmpdir("milk-tea-package-manifest-default-kind") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "src", "main.mt"), "")
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"

        [build]
        entry = "src/main.mt"
      TOML

      manifest = MilkTea::PackageManifest.load(dir)

      assert_equal :application, manifest.package_kind
    end
  end

  def test_load_accepts_explicit_library_kind
    Dir.mktmpdir("milk-tea-package-manifest-library") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "lib"
        kind = "library"
        source_root = "src"
      TOML

      manifest = MilkTea::PackageManifest.load(dir)

      assert_equal :library, manifest.package_kind
      assert_nil manifest.source_path
    end
  end

  def test_load_rejects_missing_html_template
    Dir.mktmpdir("milk-tea-package-manifest-missing-template") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "src", "main.mt"), "")
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"

        [build]
        entry = "src/main.mt"
        html_template = "nonexistent.html"
      TOML

      error = assert_raises(MilkTea::PackageManifestError) do
        MilkTea::PackageManifest.load(dir)
      end

      assert_match(/html_template not found/, error.message)
    end
  end

  def test_load_resolves_manifest_from_subdirectory
    Dir.mktmpdir("milk-tea-package-manifest-subdir") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src", "game"))
      File.write(File.join(dir, "src", "game", "player.mt"), "")
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"
      TOML

      manifest = MilkTea::PackageManifest.load(File.join(dir, "src", "game", "player.mt"))

      assert_equal "app", manifest.package_name
      assert_equal File.expand_path(dir), manifest.root_dir
    end
  end

  def test_load_normalizes_darwin_platform
    Dir.mktmpdir("milk-tea-package-manifest-darwin") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"

        [platform]
        default = "macos"
      TOML

      manifest = MilkTea::PackageManifest.load(dir)

      assert_equal :darwin, manifest.platform
    end
  end

  def test_load_normalizes_app_and_lib_kind_aliases
    Dir.mktmpdir("milk-tea-package-manifest-kind-aliases") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "app"
        kind = "app"
        source_root = "src"
      TOML

      manifest = MilkTea::PackageManifest.load(dir)

      assert_equal :application, manifest.package_kind
    end
  end

end
