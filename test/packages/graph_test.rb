# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaPackageGraphTest < Minitest::Test
  def test_load_builds_a_graph_from_a_single_application_package
    Dir.mktmpdir("milk-tea-package-graph-single") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "src", "main.mt"), "")
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"
      TOML

      root = MilkTea::PackageGraph.load(dir)

      assert_equal "snake_duel", root.manifest.package_name
      assert_equal [], root.edges
      assert_equal File.expand_path(File.join(dir, "src")), root.manifest.source_root
    end
  end

  def test_load_builds_graph_with_local_path_dependencies
    Dir.mktmpdir("milk-tea-package-graph-deps") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(ui_root, "src"))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "0.1.0"
        kind = "library"
        source_root = "src"
      TOML

      root = MilkTea::PackageGraph.load(app_root)

      assert_equal "snake_duel", root.manifest.package_name
      assert_equal 1, root.edges.length
      assert_equal "teefan.ui", root.edges.first.node.manifest.package_name
    end
  end

  def test_load_detects_dependency_cycles
    Dir.mktmpdir("milk-tea-package-graph-cycle") do |dir|
      pkg_a = File.join(dir, "a")
      pkg_b = File.join(dir, "b")
      FileUtils.mkdir_p(File.join(pkg_a, "src"))
      FileUtils.mkdir_p(File.join(pkg_b, "src"))

      File.write(File.join(pkg_a, "package.toml"), <<~TOML)
        [package]
        name = "a"
        source_root = "src"

        [dependencies]
        "b" = { path = "../b" }
      TOML

      File.write(File.join(pkg_b, "package.toml"), <<~TOML)
        [package]
        name = "b"
        source_root = "src"

        [dependencies]
        "a" = { path = "../a" }
      TOML

      error = assert_raises(MilkTea::PackageGraphError) do
        MilkTea::PackageGraph.load(pkg_a)
      end

      assert_match(/cycle/, error.message)
    end
  end

  def test_source_roots_collects_all_dependency_source_roots
    Dir.mktmpdir("milk-tea-package-graph-roots") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(ui_root, "src"))

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

      root = MilkTea::PackageGraph.load(app_root)
      roots = root.source_roots

      assert_equal 2, roots.length
      assert_includes roots, File.expand_path(File.join(app_root, "src"))
      assert_includes roots, File.expand_path(File.join(ui_root, "src"))
    end
  end

  def test_package_for_path_finds_correct_package_with_longest_prefix_match
    Dir.mktmpdir("milk-tea-package-graph-path-match") do |dir|
      app_root = File.join(dir, "apps", "tetris")
      pieces_root = File.join(dir, "libs", "tetris.pieces")
      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(pieces_root, "src"))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "tetris"
        source_root = "src"

        [dependencies]
        "tetris.pieces" = { path = "../../libs/tetris.pieces" }
      TOML

      File.write(File.join(pieces_root, "package.toml"), <<~TOML)
        [package]
        name = "tetris.pieces"
        kind = "library"
        source_root = "src"
      TOML

      root = MilkTea::PackageGraph.load(app_root)

      app_match = root.package_for_path(File.join(app_root, "src", "main.mt"))
      pieces_match = root.package_for_path(File.join(pieces_root, "src", "defs.mt"))

      refute_nil app_match
      assert_equal "tetris", app_match.manifest.package_name
      refute_nil pieces_match
      assert_equal "tetris.pieces", pieces_match.manifest.package_name
    end
  end

  def test_tree_lines_renders_dependency_hierarchy
    Dir.mktmpdir("milk-tea-package-graph-tree") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(ui_root, "src"))

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

      root = MilkTea::PackageGraph.load(app_root)
      lines = root.tree_lines

      assert_equal "snake_duel", lines[0]
      assert_equal "  teefan.ui", lines[1]
    end
  end

  def test_load_respects_library_package_without_entry_point
    Dir.mktmpdir("milk-tea-package-graph-library") do |dir|
      lib_root = File.join(dir, "libs", "my-lib")
      FileUtils.mkdir_p(File.join(lib_root, "src"))

      File.write(File.join(lib_root, "package.toml"), <<~TOML)
        [package]
        name = "my_lib"
        kind = "library"
        source_root = "src"
      TOML

      root = MilkTea::PackageGraph.load(lib_root)

      assert_equal "my_lib", root.manifest.package_name
      assert_equal :library, root.manifest.package_kind
      assert_nil root.manifest.source_path
    end
  end

  def test_load_rejects_missing_dependency_path
    Dir.mktmpdir("milk-tea-package-graph-missing-dep") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"

        [dependencies]
        "missing.pkg" = { path = "../nonexistent" }
      TOML

      error = assert_raises(MilkTea::PackageManifestError) do
        MilkTea::PackageGraph.load(dir)
      end

      assert_match(/path not found/, error.message)
    end
  end

  def test_load_rejects_version_constraint_mismatch_on_path_dependency
    Dir.mktmpdir("milk-tea-package-graph-version-mismatch") do |dir|
      app_root = File.join(dir, "apps", "app")
      lib_root = File.join(dir, "libs", "lib")
      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(lib_root, "src"))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"

        [dependencies]
        "lib" = { path = "../../libs/lib", version = "2.0.0" }
      TOML

      File.write(File.join(lib_root, "package.toml"), <<~TOML)
        [package]
        name = "lib"
        version = "1.0.0"
        kind = "library"
        source_root = "src"
      TOML

      error = assert_raises(MilkTea::PackageSourceResolverError) do
        MilkTea::PackageGraph.load(app_root)
      end

      assert_match(/does not satisfy/, error.message)
    end
  end

  def test_packages_collects_all_nodes_in_graph
    Dir.mktmpdir("milk-tea-package-graph-packages") do |dir|
      app_root = File.join(dir, "apps", "app")
      lib_a = File.join(dir, "libs", "a")
      lib_b = File.join(dir, "libs", "b")
      FileUtils.mkdir_p(File.join(app_root, "src"))
      FileUtils.mkdir_p(File.join(lib_a, "src"))
      FileUtils.mkdir_p(File.join(lib_b, "src"))

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "app"
        source_root = "src"

        [dependencies]
        "a" = { path = "../../libs/a" }
        "b" = { path = "../../libs/b" }
      TOML

      File.write(File.join(lib_a, "package.toml"), <<~TOML)
        [package]
        name = "a"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(lib_b, "package.toml"), <<~TOML)
        [package]
        name = "b"
        kind = "library"
        source_root = "src"
      TOML

      root = MilkTea::PackageGraph.load(app_root)
      packages = root.packages

      assert_equal 3, packages.length
      names = packages.map { |node| node.manifest.package_name }
      assert_includes names, "app"
      assert_includes names, "a"
      assert_includes names, "b"
    end
  end

  def test_render_tree_class_method_produces_formatted_output
    Dir.mktmpdir("milk-tea-package-graph-render") do |dir|
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

      tree = MilkTea::PackageGraph.render_tree(app_root)

      assert_equal "app\n  lib", tree
    end
  end
end
