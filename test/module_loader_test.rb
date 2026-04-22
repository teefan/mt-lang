# frozen_string_literal: true

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
    assert_equal %w[demo.bouncing_ball std.c.raylib], program.analyses_by_module_name.keys.sort
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

  private

  def demo_path
    File.expand_path("../examples/milk-tea-demo.mt", __dir__)
  end
end
