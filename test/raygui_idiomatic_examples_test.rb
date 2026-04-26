# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

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
      refute_match(/using addr\(/, source)
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

  def test_idiomatic_examples_build_with_fake_compiler
    Dir.mktmpdir("milk-tea-raygui-idiomatic-examples") do |dir|
      compiler_log = File.join(dir, "compiler.log")
      compiler_path = write_fake_compiler(dir, compiler_log)

      idiomatic_example_paths.each do |path|
        output_basename = File.basename(path, ".mt")
        output_path = File.join(dir, output_basename)
        c_path = File.join(dir, "#{output_basename}.c")

        result = MilkTea::Build.build(path, output_path:, cc: compiler_path, keep_c_path: c_path)

        assert_equal File.expand_path(output_path), result.output_path
        assert_equal File.expand_path(c_path), result.c_path
        assert_equal File.expand_path(compiler_path), result.compiler
        assert_includes result.link_flags, "-lraylib"
        assert_includes result.link_flags, "-lm"
        assert File.exist?(output_path)
        assert File.exist?(c_path)
        assert_match(/#include "raylib\.h"/, File.read(c_path))
        assert_match(/#include "raygui\.h"/, File.read(c_path))
      end

      invocation = File.read(compiler_log).lines(chomp: true)
      assert_includes invocation, "-std=c11"
      assert_includes invocation, "-lraylib"
      assert_includes invocation, "-lm"
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
    Dir[File.expand_path("../examples/idiomatic/raygui/*.mt", __dir__)].sort
  end

  def module_name_for(path)
    relative_path = path.delete_prefix(File.expand_path("../examples/", __dir__) + "/")
    "examples.#{relative_path.delete_suffix(".mt").tr("/", ".")}"
  end

  def write_fake_compiler(dir, log_path)
    path = File.join(dir, "fake-cc")
    File.write(path, <<~SH)
      #!/bin/sh
      printf '%s\n' "$@" > #{log_path.inspect}
      output=''
      previous=''
      for argument in "$@"; do
        if [ "$previous" = '-o' ]; then
          output="$argument"
        fi
        previous="$argument"
      done
      : > "$output"
    SH
    File.chmod(0o755, path)
    path
  end
end
