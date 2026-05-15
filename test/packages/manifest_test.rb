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
end
