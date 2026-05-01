# frozen_string_literal: true

require_relative "../test_helper"

class MilkTeaRayguiIdiomaticExamplesTest < Minitest::Test
  def test_idiomatic_examples_use_curated_surface_only
    idiomatic_example_paths.each do |path|
      source = File.read(path)

      assert_match(/^module examples\.idiomatic\.raygui\./, source)
      assert_match(/^import std\.raylib as rl$/, source)
      assert_match(/^import std\.raygui as gui$/, source)
      refute_match(/^import std\.mem\.arena as /, source)
      refute_match(/^import std\.c\.raylib as /, source)
      refute_match(/^import std\.c\.raygui as /, source)
      refute_match(/^\s*unsafe:/, source)
      refute_match(/using ref_of\(/, source)
      refute_match(/\bptr_of\(/, source)
      refute_match(/c"/, source)
    end
  end

  def test_idiomatic_examples_check_and_lower
    idiomatic_example_paths.each do |path|
      program = MilkTea::ModuleLoader.check_program(path)

      assert_equal true, program.analyses_by_module_name.key?(module_name_for(path))
    end
  end

  def test_idiomatic_examples_codegen_avoids_reviewed_noise
    generated = idiomatic_example_paths.to_h do |path|
      program = MilkTea::ModuleLoader.check_program(path)
      [File.basename(path), MilkTea::Codegen.generate_c(program)]
    end

    controls = generated.fetch("controls_showcase.mt")
    dynamic = generated.fetch("dynamic_string_lists_showcase.mt")
    text_builders = generated.fetch("text_builders_showcase.mt")

    refute_match(/mt_foreign_strs_to_cstrs_temp/, controls)
    refute_match(/mt_free_foreign_cstrs_temp/, controls)
    refute_match(/mt_foreign_strs_to_cstrs_temp/, dynamic)
    refute_match(/mt_free_foreign_cstrs_temp/, dynamic)

    refute_match(/static void mt_panic_str\(/, controls)
    refute_match(/static void mt_panic_str\(/, dynamic)
    refute_match(/static void mt_panic_str\(/, text_builders)
    refute_match(/if \(64 == 64\)/, text_builders)
  end

  private

  def idiomatic_example_paths
    Dir[File.expand_path("../../examples/idiomatic/raygui/*.mt", __dir__)].sort
  end

  def module_name_for(path)
    relative_path = path.delete_prefix(File.expand_path("../../examples/", __dir__) + "/")
    "examples.#{relative_path.delete_suffix(".mt").tr("/", ".")}"
  end

end
