# frozen_string_literal: true

require_relative "../test_helper"

class MilkTeaSdl3IdiomaticExamplesTest < Minitest::Test
  def test_idiomatic_examples_use_curated_surface_only
    idiomatic_example_paths.each do |path|
      source = File.read(path)

      assert_match(/^module examples\.idiomatic\.sdl3\./, source)
      assert_match(/^import std\.sdl3 as sdl$/, source)
      refute_match(/^import std\.c\.sdl3 as sdl$/, source)
      refute_match(/^\s*unsafe:/, source)
      refute_match(/\braw\(/, source)
      refute_match(/c"/, source)
    end
  end

  def test_idiomatic_examples_check_and_lower
    idiomatic_example_paths.each do |path|
      program = MilkTea::ModuleLoader.check_program(path)

      assert_equal true, program.analyses_by_module_name.key?(module_name_for(path))
    end
  end

  private

  def idiomatic_example_paths
    Dir[File.expand_path("../../examples/idiomatic/sdl3/*.mt", __dir__)].sort
  end

  def module_name_for(path)
    relative_path = path.delete_prefix(File.expand_path("../../examples/", __dir__) + "/")
    "examples.#{relative_path.delete_suffix(".mt").tr("/", ".")}"
  end
end
