# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaModuleRootsTest < Minitest::Test
  def test_roots_for_path_defaults_to_nearest_package_source_root
    Dir.mktmpdir("milk-tea-module-roots") do |dir|
      package_root = File.join(dir, "projects", "snake-duel")
      src_dir = File.join(package_root, "src")
      FileUtils.mkdir_p(src_dir)
      File.write(File.join(package_root, "package.toml"), "[package]\nname = \"snake_duel\"\n")
      source_path = File.join(src_dir, "main.mt")
      File.write(source_path, "module main\n")

      roots = MilkTea::ModuleRoots.roots_for_path(source_path)

      assert_includes roots, File.expand_path(src_dir)
    end
  end

  def test_roots_for_path_uses_package_source_root_and_path_dependencies
    Dir.mktmpdir("milk-tea-module-roots-dependencies") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      ui_src_dir = File.join(ui_root, "src", "teefan", "ui")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        kind = "library"
        source_root = "src"
      TOML

      source_path = File.join(app_src_dir, "main.mt")
      File.write(source_path, <<~MT)
        module snake_duel.main

        import teefan.ui.layout as layout

        function main() -> int:
            return layout.default_width()
      MT

      File.write(File.join(ui_src_dir, "layout.mt"), <<~MT)
        module teefan.ui.layout

        public function default_width() -> int:
            return 10
      MT

      roots = MilkTea::ModuleRoots.roots_for_path(source_path)

      assert_includes roots, File.expand_path(File.join(app_root, "src"))
      assert_includes roots, File.expand_path(File.join(ui_root, "src"))
      refute_includes roots, File.expand_path(app_root)
      refute_includes roots, File.expand_path(ui_root)
    end
  end

  def test_roots_for_path_rejects_package_dependency_cycles
    Dir.mktmpdir("milk-tea-module-roots-cycle") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      app_src_dir = File.join(app_root, "src")
      ui_src_dir = File.join(ui_root, "src")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        kind = "library"
        source_root = "src"

        [dependencies]
        "snake_duel" = { path = "../../apps/snake-duel" }
      TOML

      error = assert_raises(MilkTea::PackageGraphError) do
        MilkTea::ModuleRoots.roots_for_path(app_root)
      end

      assert_match(/package dependency cycle detected/, error.message)
    end
  end

  def test_roots_for_path_keeps_project_root
    virtual_path = File.join(MilkTea.root.to_s, "tmp", "virtual-source.mt")
    roots = MilkTea::ModuleRoots.roots_for_path(virtual_path)

    assert_includes roots, File.expand_path("../..", __dir__)
  end
end
