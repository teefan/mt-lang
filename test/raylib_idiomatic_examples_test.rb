# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaRaylibIdiomaticExamplesTest < Minitest::Test
  def test_idiomatic_examples_use_curated_surface_only
    idiomatic_example_paths.each do |path|
      source = File.read(path)

      assert_match(/^module examples\.idiomatic\.raylib\./, source)
      assert_match(/^import std\.raylib as rl$/, source)
      refute_match(/^import std\.c\.raylib as rl$/, source)
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

  def test_idiomatic_examples_build_with_fake_compiler
    Dir.mktmpdir("milk-tea-raylib-idiomatic-examples") do |dir|
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
        assert File.exist?(output_path)
        assert File.exist?(c_path)
        assert_match(/#include "raylib\.h"/, File.read(c_path))
      end

      invocation = File.read(compiler_log).lines(chomp: true)
      assert_includes invocation, "-std=c11"
      assert_includes invocation, "-lraylib"
    end
  end

  private

  def idiomatic_example_paths
    Dir[File.expand_path("../examples/idiomatic/raylib/*.mt", __dir__)].sort
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
