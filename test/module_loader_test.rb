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

  private

  def demo_path
    File.expand_path("../examples/milk-tea-demo.mt", __dir__)
  end
end
