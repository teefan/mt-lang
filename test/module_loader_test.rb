# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "test_helper"

class MilkTeaModuleLoaderTest < Minitest::Test
  def test_load_file_parses_demo_file
    ast = MilkTea::ModuleLoader.load_file(demo_path)

    assert_equal "demo.bouncing_ball", ast.module_name.to_s
    assert_equal 6, ast.declarations.length
  end

  def test_load_file_reports_missing_files
    error = assert_raises(MilkTea::ModuleLoadError) do
      MilkTea::ModuleLoader.load_file(File.expand_path("missing.mt", __dir__))
    end

    assert_match(/source file not found/, error.message)
  end

  def test_check_file_runs_semantic_analysis
    result = MilkTea::ModuleLoader.check_file(demo_path)

    assert_equal "demo.bouncing_ball", result.module_name
    assert_equal %w[main], result.functions.keys.sort
  end

  def test_check_program_exposes_root_and_imported_modules
    program = MilkTea::ModuleLoader.check_program(demo_path)

    assert_equal demo_path, program.root_path
    assert_equal "demo.bouncing_ball", program.root_analysis.module_name
    assert_equal %w[demo.bouncing_ball std.c.raylib std.raylib], program.analyses_by_module_name.keys.sort
    assert_equal :module, program.analyses_by_module_name.fetch("std.raylib").module_kind
    assert_equal :extern_module, program.analyses_by_module_name.fetch("std.c.raylib").module_kind
  end

  def test_check_file_reports_missing_imported_modules
    source_path = File.expand_path("missing-import.mt", __dir__)
    File.write(source_path, <<~MT)
      module demo.bad

      import std.c.missing as missing

      def main() -> i32:
          return 0
    MT

    error = assert_raises(MilkTea::ModuleLoadError) do
      MilkTea::ModuleLoader.check_file(source_path)
    end

    assert_match(/module not found/, error.message)
  ensure
    File.delete(source_path) if source_path && File.exist?(source_path)
  end

  def test_check_program_exports_only_public_declarations_from_imports
    Dir.mktmpdir("milk-tea-module-loader-visibility") do |dir|
      root_path = File.join(dir, "demo", "main.mt")
      lib_path = File.join(dir, "demo", "lib.mt")

      FileUtils.mkdir_p(File.dirname(root_path))
      File.write(root_path, <<~MT)
        module demo.main

        import demo.lib as lib

        def main() -> i32:
            let counter = lib.Counter(value = lib.answer)
            return counter.read()
      MT

      File.write(lib_path, <<~MT)
        module demo.lib

        pub const answer: i32 = 7
        const hidden: i32 = 9

        pub struct Counter:
            value: i32

        struct Hidden:
            value: i32

        methods Counter:
            pub def read() -> i32:
                return this.value

            def bump() -> i32:
                return this.value + 1

        pub def make_counter() -> Counter:
            return Counter(value = answer)

        def hidden_fn() -> i32:
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

  private

  def demo_path
    File.expand_path("../examples/milk-tea-demo.mt", __dir__)
  end
end
