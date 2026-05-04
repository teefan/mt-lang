# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaModuleRootsTest < Minitest::Test
  def test_roots_for_path_includes_nearest_package_root
    Dir.mktmpdir("milk-tea-module-roots") do |dir|
      package_root = File.join(dir, "projects", "snake-duel")
      src_dir = File.join(package_root, "src")
      FileUtils.mkdir_p(src_dir)
      File.write(File.join(package_root, "package.toml"), "[package]\nname = \"snake_duel\"\n")
      source_path = File.join(src_dir, "main.mt")
      File.write(source_path, "module demo.main\n")

      roots = MilkTea::ModuleRoots.roots_for_path(source_path)

      assert_includes roots, File.expand_path(package_root)
    end
  end

  def test_roots_for_path_keeps_project_root
    roots = MilkTea::ModuleRoots.roots_for_path(File.expand_path("../../examples/milk-tea-demo.mt", __dir__))

    assert_includes roots, File.expand_path("../..", __dir__)
  end
end
