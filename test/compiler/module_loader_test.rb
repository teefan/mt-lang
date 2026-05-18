# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../test_helper"

class MilkTeaModuleLoaderTest < Minitest::Test
  def test_load_file_parses_language_fixture_file
    ast = MilkTea::ModuleLoader.load_file(language_fixture_path)

    assert_equal "test.fixtures.language_fixture", ast.module_name.to_s
    assert_equal 6, ast.declarations.length
  end

  def test_load_file_reports_missing_files
    error = assert_raises(MilkTea::ModuleLoadError) do
      MilkTea::ModuleLoader.load_file(File.expand_path("missing.mt", __dir__))
    end

    assert_match(/source file not found/, error.message)
  end

  def test_check_file_runs_semantic_analysis
    result = MilkTea::ModuleLoader.check_file(language_fixture_path)

    assert_equal "test.fixtures.language_fixture", result.module_name
    assert_equal %w[describe main], result.functions.keys.sort
  end

  def test_check_program_exposes_root_and_imported_modules
    program = MilkTea::ModuleLoader.check_program(language_fixture_path)
    loaded_modules = program.analyses_by_module_name.keys

    assert_equal language_fixture_path, program.root_path
    assert_equal "test.fixtures.language_fixture", program.root_analysis.module_name
    assert_includes loaded_modules, "test.fixtures.language_fixture"
    assert_includes loaded_modules, "test.fixtures.language_fixture.external_runtime"
    assert_includes loaded_modules, "test.fixtures.language_fixture.types"
    assert_equal :raw_module, program.analyses_by_module_name.fetch("test.fixtures.language_fixture.external_runtime").module_kind
  end

  def test_check_program_does_not_auto_load_std_fmt_for_plain_format_strings
    Dir.mktmpdir("milk-tea-module-loader-format-string") do |dir|
      root_path = File.join(dir, "demo", "main.mt")

      FileUtils.mkdir_p(File.dirname(root_path))
      File.write(root_path, <<~MT)
        function main() -> int:
            let count = 7
            let text = f"count=\#{count}"
            if text.len == 0:
                return 1
            return 0
      MT

      program = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
      loaded_modules = program.analyses_by_module_name.keys

      assert_includes loaded_modules, "demo.main"
      refute_includes loaded_modules, "std.fmt"
      refute_includes loaded_modules, "std.string"
    end
  end

  def test_check_file_reports_missing_imported_modules
    source_path = File.expand_path("missing-import.mt", __dir__)
    File.write(source_path, <<~MT)
      import std.c.missing as missing

      function main() -> int:
          return 0
    MT

    error = assert_raises(MilkTea::ModuleLoadError) do
      MilkTea::ModuleLoader.check_file(source_path)
    end

    assert_match(/module not found/, error.message)
  ensure
    File.delete(source_path) if source_path && File.exist?(source_path)
  end

  def test_check_program_infers_package_module_name_relative_to_source_root
    Dir.mktmpdir("milk-tea-module-loader-package-module-path-mismatch") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "tetris"
        source_root = "src"

        [build]
        entry = "src/main.mt"
      TOML

      root_path = File.join(dir, "src", "main.mt")
      File.write(root_path, <<~MT)
        function main() -> int:
            return 0
      MT

      program = MilkTea::ModuleLoader.new(module_roots: MilkTea::ModuleRoots.roots_for_path(root_path)).check_program(root_path)

      assert_equal "main", program.root_analysis.module_name
    end
  end

  def test_check_program_reports_entry_module_namespace_trap_for_missing_sibling_import
    Dir.mktmpdir("milk-tea-module-loader-entry-namespace-trap") do |dir|
      FileUtils.mkdir_p(File.join(dir, "src"))
      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "tetris"

        [build]
        entry = "src/main.mt"
      TOML

      root_path = File.join(dir, "src", "main.mt")
      File.write(root_path, <<~MT)
        import main.platform_info as platform_info

        function main() -> int:
            return 0
      MT

      File.write(File.join(dir, "src", "platform_info.mt"), <<~MT)
        public function label() -> str:
            return "Build: Shared"
      MT

      error = assert_raises(MilkTea::ModuleLoadError) do
        MilkTea::ModuleLoader.new(module_roots: MilkTea::ModuleRoots.roots_for_path(root_path)).check_program(root_path)
      end

      assert_match(/entry module 'main' does not create an import namespace for sibling files/, error.message)
      assert_match(/Import 'platform_info' instead/, error.message)
    end
  end

  def test_check_program_exports_only_public_declarations_from_imports
    Dir.mktmpdir("milk-tea-module-loader-visibility") do |dir|
      root_path = File.join(dir, "demo", "main.mt")
      lib_path = File.join(dir, "demo", "lib.mt")

      FileUtils.mkdir_p(File.dirname(root_path))
      File.write(root_path, <<~MT)
        import demo.lib as lib

        function main() -> int:
            let counter = lib.Counter(value = lib.answer)
            return counter.read()
      MT

      File.write(lib_path, <<~MT)
        public const answer: int = 7
        const hidden: int = 9

        public struct Counter:
            value: int

        struct Hidden:
            value: int

        extending Counter:
            public function read() -> int:
                return this.value

            function bump() -> int:
                return this.value + 1

        public function make_counter() -> Counter:
            return Counter(value = answer)

        function hidden_fn() -> int:
            return hidden
      MT

      program = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
      imported = program.root_analysis.imports.fetch("lib")
      counter_type = imported.types.fetch("Counter")

      assert_equal %w[Counter], imported.types.keys.sort
      assert_equal %w[answer], imported.values.keys.sort
      assert_equal %w[make_counter], imported.functions.keys.sort
      assert_equal %w[read], imported.methods.fetch(counter_type).keys.sort
    end
  end

  def test_check_program_resolves_path_dependency_package_modules
    Dir.mktmpdir("milk-tea-module-loader-package-dependencies") do |dir|
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

        [build]
        entry = "src/snake_duel/main.mt"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        kind = "library"
        source_root = "src"
      TOML

      root_path = File.join(app_src_dir, "main.mt")
      File.write(root_path, <<~MT)
        import teefan.ui.layout as layout

        function main() -> int:
            return layout.default_width()
      MT

      File.write(File.join(ui_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      program = MilkTea::ModuleLoader.new(module_roots: MilkTea::ModuleRoots.roots_for_path(root_path)).check_program(root_path)

      assert_equal "snake_duel.main", program.root_analysis.module_name
      assert_equal true, program.analyses_by_module_name.key?("teefan.ui.layout")
      assert_equal %w[default_width], program.root_analysis.imports.fetch("layout").functions.keys.sort
    end
  end

  def test_check_program_prefers_more_specific_dependency_namespace_over_root_package_namespace
    Dir.mktmpdir("milk-tea-module-loader-package-prefix") do |dir|
      app_root = File.join(dir, "apps", "tetris")
      pieces_root = File.join(app_root, "packages", "tetris_pieces")
      app_src_dir = File.join(app_root, "src")
      pieces_src_dir = File.join(pieces_root, "src", "tetris", "pieces")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(pieces_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "tetris"
        version = "0.1.0"

        [build]
        entry = "src/main.mt"

        [dependencies]
        "tetris.pieces" = { path = "packages/tetris_pieces", version = "0.1.0" }
      TOML

      File.write(File.join(pieces_root, "package.toml"), <<~TOML)
        [package]
        name = "tetris.pieces"
        version = "0.1.0"
        kind = "library"
        source_root = "src"
      TOML

      root_path = File.join(app_src_dir, "main.mt")
      File.write(root_path, <<~MT)
        import tetris.pieces.defs as pieces

        function main() -> int:
            return pieces.spawn_value()
      MT

      File.write(File.join(pieces_src_dir, "defs.mt"), <<~MT)
        public function spawn_value() -> int:
            return 4
      MT

      program = MilkTea::ModuleLoader.new(module_roots: MilkTea::ModuleRoots.roots_for_path(root_path)).check_program(root_path)

      assert_equal true, program.analyses_by_module_name.key?("tetris.pieces.defs")
      assert_equal %w[spawn_value], program.root_analysis.imports.fetch("pieces").functions.keys.sort
    end
  end

  def test_check_program_prefers_platform_specific_module_variant_over_shared_module
    Dir.mktmpdir("milk-tea-module-loader-platform-variant") do |dir|
      root_path = File.join(dir, "demo", "main.mt")
      shared_path = File.join(dir, "demo", "support.mt")
      windows_path = File.join(dir, "demo", "support.windows.mt")

      FileUtils.mkdir_p(File.dirname(root_path))

      File.write(root_path, <<~MT)
        import demo.support as support

        function main() -> int:
            return support.value()
      MT

      File.write(shared_path, <<~MT)
        public function value() -> int:
            return 1
      MT

      File.write(windows_path, <<~MT)
        public function value() -> int:
            return 2
      MT

      program = MilkTea::ModuleLoader.new(module_roots: [dir], platform: :windows).check_program(root_path)

      assert_includes program.analyses_by_path.keys, File.expand_path(windows_path)
      refute_includes program.analyses_by_path.keys, File.expand_path(shared_path)
      assert_equal %w[value], program.root_analysis.imports.fetch("support").functions.keys.sort
    end
  end

  def test_check_program_allows_dependency_packages_to_import_their_own_direct_dependencies
    Dir.mktmpdir("milk-tea-module-loader-transitive-allowed") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      math_root = File.join(dir, "libs", "math")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      ui_src_dir = File.join(ui_root, "src", "teefan", "ui")
      math_src_dir = File.join(math_root, "src", "teefan", "math")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)
      FileUtils.mkdir_p(math_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [build]
        entry = "src/snake_duel/main.mt"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        kind = "library"
        source_root = "src"

        [dependencies]
        "teefan.math" = { path = "../math" }
      TOML

      File.write(File.join(math_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.math"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(app_src_dir, "main.mt"), <<~MT)
        import teefan.ui.layout as layout

        function main() -> int:
            return layout.default_width()
      MT

      File.write(File.join(ui_src_dir, "layout.mt"), <<~MT)
        import teefan.math.ops as ops

        public function default_width() -> int:
            return ops.bump(9)
      MT

      File.write(File.join(math_src_dir, "ops.mt"), <<~MT)
        public function bump(value: int) -> int:
            return value + 1
      MT

      program = MilkTea::ModuleLoader.new(module_roots: MilkTea::ModuleRoots.roots_for_path(File.join(app_src_dir, "main.mt"))).check_program(File.join(app_src_dir, "main.mt"))

      assert_equal true, program.analyses_by_module_name.key?("teefan.ui.layout")
      assert_equal true, program.analyses_by_module_name.key?("teefan.math.ops")
    end
  end

  def test_check_program_locked_resolves_duplicate_package_names_by_exact_dependency_instance
    Dir.mktmpdir("milk-tea-module-loader-locked-package-instances") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      overlay_root = File.join(dir, "libs", "overlay")
      ui_v1_root = File.join(dir, "libs", "ui-v1")
      ui_v2_root = File.join(dir, "libs", "ui-v2")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      overlay_src_dir = File.join(overlay_root, "src", "teefan", "overlay")
      ui_v1_src_dir = File.join(ui_v1_root, "src", "teefan", "ui")
      ui_v2_src_dir = File.join(ui_v2_root, "src", "teefan", "ui")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(overlay_src_dir)
      FileUtils.mkdir_p(ui_v1_src_dir)
      FileUtils.mkdir_p(ui_v2_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"
      TOML

      File.write(File.join(overlay_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.overlay"
        version = "0.1.0"
        kind = "library"
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

      root_path = File.join(app_src_dir, "main.mt")
      File.write(root_path, <<~MT)
        import teefan.ui.layout as layout
        import teefan.overlay.panel as panel

        function main() -> int:
            return layout.default_width() + panel.overlay_width()
      MT

      File.write(File.join(overlay_src_dir, "panel.mt"), <<~MT)
        import teefan.ui.layout as layout

        public function overlay_width() -> int:
            return layout.overlay_width()
      MT

      File.write(File.join(ui_v1_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      File.write(File.join(ui_v2_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 20

        public function overlay_width() -> int:
            return 7
      MT

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
        source_root = #{File.join(app_root, "src").inspect}
        dependency_ids = ["overlay", "ui-v1"]

        [[package]]
        instance_id = "overlay"
        name = "teefan.overlay"
        kind = "library"
        version = "0.1.0"
        source_kind = "path"
        source_path = #{overlay_root.inspect}
        manifest_path = #{File.join(overlay_root, "package.toml").inspect}
        source_root = #{File.join(overlay_root, "src").inspect}
        dependency_ids = ["ui-v2"]

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

      program = MilkTea::ModuleLoader.new(
        module_roots: MilkTea::ModuleRoots.roots_for_path(root_path, locked: true),
        package_graph: MilkTea::PackageGraph.load(app_root, locked: true),
      ).check_program(root_path)

      overlay_analysis = program.analyses_by_path.fetch(File.join(overlay_src_dir, "panel.mt"))
      ui_v1_path = File.join(ui_v1_src_dir, "layout.mt")
      ui_v2_path = File.join(ui_v2_src_dir, "layout.mt")
      assert program.analyses_by_path.key?(ui_v1_path)
      assert program.analyses_by_path.key?(ui_v2_path)

      assert_equal %w[default_width], program.root_analysis.imports.fetch("layout").functions.keys.sort
      assert_equal %w[default_width overlay_width], overlay_analysis.imports.fetch("layout").functions.keys.sort
    end
  end

  def test_check_program_live_resolves_duplicate_package_names_by_exact_dependency_instance
    Dir.mktmpdir("milk-tea-module-loader-live-package-instances") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      overlay_root = File.join(dir, "libs", "overlay")
      ui_v1_root = File.join(dir, "libs", "ui-v1")
      ui_v2_root = File.join(dir, "libs", "ui-v2")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      overlay_src_dir = File.join(overlay_root, "src", "teefan", "overlay")
      ui_v1_src_dir = File.join(ui_v1_root, "src", "teefan", "ui")
      ui_v2_src_dir = File.join(ui_v2_root, "src", "teefan", "ui")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(overlay_src_dir)
      FileUtils.mkdir_p(ui_v1_src_dir)
      FileUtils.mkdir_p(ui_v2_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.overlay" = { path = "../../libs/overlay" }
        "teefan.ui" = { path = "../../libs/ui-v1" }
      TOML

      File.write(File.join(overlay_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.overlay"
        version = "0.1.0"
        kind = "library"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../ui-v2" }
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

      root_path = File.join(app_src_dir, "main.mt")
      File.write(root_path, <<~MT)
        import teefan.ui.layout as layout
        import teefan.overlay.panel as panel

        function main() -> int:
            return layout.default_width() + panel.overlay_width()
      MT

      File.write(File.join(overlay_src_dir, "panel.mt"), <<~MT)
        import teefan.ui.layout as layout

        public function overlay_width() -> int:
            return layout.overlay_width()
      MT

      File.write(File.join(ui_v1_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      File.write(File.join(ui_v2_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 20

        public function overlay_width() -> int:
            return 7
      MT

      program = MilkTea::ModuleLoader.new(
        module_roots: MilkTea::ModuleRoots.roots_for_path(root_path),
        package_graph: MilkTea::PackageGraph.load(root_path),
      ).check_program(root_path)

      overlay_analysis = program.analyses_by_path.fetch(File.join(overlay_src_dir, "panel.mt"))
      ui_v1_path = File.join(ui_v1_src_dir, "layout.mt")
      ui_v2_path = File.join(ui_v2_src_dir, "layout.mt")
      assert program.analyses_by_path.key?(ui_v1_path)
      assert program.analyses_by_path.key?(ui_v2_path)

      assert_equal %w[default_width], program.root_analysis.imports.fetch("layout").functions.keys.sort
      assert_equal %w[default_width overlay_width], overlay_analysis.imports.fetch("layout").functions.keys.sort
    end
  end

  def test_check_program_rejects_transitive_dependency_imports_from_root_package
    Dir.mktmpdir("milk-tea-module-loader-transitive-blocked") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      math_root = File.join(dir, "libs", "math")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      ui_src_dir = File.join(ui_root, "src", "teefan", "ui")
      math_src_dir = File.join(math_root, "src", "teefan", "math")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)
      FileUtils.mkdir_p(math_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        source_root = "src"

        [build]
        entry = "src/snake_duel/main.mt"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        kind = "library"
        source_root = "src"

        [dependencies]
        "teefan.math" = { path = "../math" }
      TOML

      File.write(File.join(math_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.math"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(app_src_dir, "main.mt"), <<~MT)
        import teefan.ui.layout as layout
        import teefan.math.ops as ops

        function main() -> int:
            return layout.default_width() + ops.bump(1)
      MT

      File.write(File.join(ui_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      File.write(File.join(math_src_dir, "ops.mt"), <<~MT)
        public function bump(value: int) -> int:
            return value + 1
      MT

      error = assert_raises(MilkTea::ModuleLoadError) do
        MilkTea::ModuleLoader.new(module_roots: MilkTea::ModuleRoots.roots_for_path(File.join(app_src_dir, "main.mt"))).check_program(File.join(app_src_dir, "main.mt"))
      end

      assert_match(/package dependency not declared/, error.message)
    end
  end

  def test_check_program_resolves_raw_module_imported_types
    Dir.mktmpdir("milk-tea-module-loader-extern-imports") do |dir|
      dep_path = File.join(dir, "std", "c", "dep.mt")
      helper_path = File.join(dir, "std", "c", "helper.mt")

      FileUtils.mkdir_p(File.dirname(dep_path))

      File.write(dep_path, <<~MT)
        external

        struct Vec:
            x: float
            y: float
      MT

      File.write(helper_path, <<~MT)
        external

        import std.c.dep as dep

        include "helper.h"

        struct Holder:
            value: dep.Vec

        external function wrap(value: dep.Vec) -> Holder
      MT

      program = MilkTea::ModuleLoader.new(module_roots: [dir]).check_program(helper_path)

      assert_equal %w[std.c.dep std.c.helper], program.analyses_by_module_name.keys.sort
      assert_equal :raw_module, program.root_analysis.module_kind
      assert_equal true, program.root_analysis.types.key?("Holder")
      assert_equal true, program.root_analysis.functions.key?("wrap")
      assert_equal true, program.root_analysis.imports.key?("dep")
    end
  end

  def test_check_program_exports_public_methods_on_imported_public_types
    Dir.mktmpdir("milk-tea-module-loader-imported-methods") do |dir|
      root_path = File.join(dir, "demo", "main.mt")
      ext_path = File.join(dir, "demo", "ext.mt")
      dep_path = File.join(dir, "demo", "dep.mt")

      FileUtils.mkdir_p(File.dirname(root_path))

      File.write(root_path, <<~MT)
        import demo.ext as ext

        function main() -> int:
            let counter = ext.make_counter()
            return counter.read()
      MT

      File.write(dep_path, <<~MT)
        public struct Counter:
            value: int
      MT

      File.write(ext_path, <<~MT)
        import demo.dep as dep

        extending dep.Counter:
            public function read() -> int:
                return this.value

        public function make_counter() -> dep.Counter:
            return dep.Counter(value = 7)
      MT

      program = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
      imported = program.root_analysis.imports.fetch("ext")
      counter_type = program.analyses_by_module_name.fetch("demo.dep").types.fetch("Counter")

      assert_equal %w[make_counter], imported.functions.keys.sort
      assert_equal %w[read], imported.methods.fetch(counter_type).keys.sort
    end
  end

  def test_check_program_exports_public_methods_on_imported_generic_receivers
    Dir.mktmpdir("milk-tea-module-loader-imported-generic-methods") do |dir|
      root_path = File.join(dir, "demo", "main.mt")
      ext_path = File.join(dir, "demo", "ext.mt")
      dep_path = File.join(dir, "demo", "dep.mt")

      FileUtils.mkdir_p(File.dirname(root_path))

      File.write(root_path, <<~MT)
        import demo.dep as dep
        import demo.ext as ext

        function main(handle: ptr[dep.Handle]) -> int:
            return handle.read_code()
      MT

      File.write(dep_path, <<~MT)
        public opaque Handle
      MT

      File.write(ext_path, <<~MT)
        import demo.dep as dep

        extending ptr[dep.Handle]:
            public function read_code() -> int:
                return 7
      MT

      program = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
      imported = program.root_analysis.imports.fetch("ext")
      handle_type = program.analyses_by_module_name.fetch("demo.dep").types.fetch("Handle")
      receiver_type = MilkTea::Types::GenericInstance.new("ptr", [handle_type])

      assert_equal %w[read_code], imported.methods.fetch(receiver_type).keys.sort
    end
  end

  def test_check_program_exports_public_methods_on_imported_generic_receiver_templates
    Dir.mktmpdir("milk-tea-module-loader-imported-generic-template-methods") do |dir|
      root_path = File.join(dir, "demo", "main.mt")
      ext_path = File.join(dir, "demo", "ext.mt")

      FileUtils.mkdir_p(File.dirname(root_path))

      File.write(root_path, <<~MT)
        import demo.ext as ext

        function main(value: const_ptr[int]) -> int:
            return value.read_value()
      MT

      File.write(ext_path, <<~MT)
        extending const_ptr[T]:
            public function read_value() -> T:
                return unsafe: read(this)
      MT

      program = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
      imported = program.root_analysis.imports.fetch("ext")
      receiver_type = MilkTea::Types::GenericInstance.new("const_ptr", [MilkTea::Types::TypeVar.new("__receiver_arg0")])

      assert_equal %w[read_value], imported.methods.fetch(receiver_type).keys.sort
    end
  end

  def test_check_program_exports_public_methods_on_imported_nullable_generic_receiver_templates
    Dir.mktmpdir("milk-tea-module-loader-imported-nullable-generic-template-methods") do |dir|
      root_path = File.join(dir, "demo", "main.mt")
      ext_path = File.join(dir, "demo", "ext.mt")

      FileUtils.mkdir_p(File.dirname(root_path))

      File.write(root_path, <<~MT)
        import demo.ext as ext

        function main(value: const_ptr[int]?) -> const_ptr[int]:
            return value.require_value("missing")
      MT

      File.write(ext_path, <<~MT)
        extending const_ptr[T]?:
            public function require_value(message: str) -> const_ptr[T]:
                if this == null:
                    fatal(message)

                return unsafe: const_ptr[T]<-this
      MT

      program = MilkTea::ModuleLoader.new(module_roots: [dir, MilkTea.root]).check_program(root_path)
      imported = program.root_analysis.imports.fetch("ext")
      receiver_type = MilkTea::Types::Nullable.new(MilkTea::Types::GenericInstance.new("const_ptr", [MilkTea::Types::TypeVar.new("__receiver_arg0")]))

      assert_equal %w[require_value], imported.methods.fetch(receiver_type).keys.sort
    end
  end

  private

  def language_fixture_path
    File.expand_path("../fixtures/language_fixture.mt", __dir__)
  end
end
