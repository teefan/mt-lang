# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaBox2DIdiomaticExamplesTest < Minitest::Test
  def test_box2d_examples_use_curated_surface_only
    idiomatic_example_paths.each do |path|
      source = File.read(path)

      assert_match(/^module examples\.idiomatic\.raylib\.box2d_/, source)
      assert_match(/^import std\.box2d as b2$/, source)
      assert_match(/^import std\.raylib as rl$/, source)
      refute_match(/^import std\.c\.(?:box2d|raylib) as /, source)
      refute_match(/^\s*unsafe:/, source)
      refute_match(/\braw\(/, source)
      refute_match(/c"/, source)
    end
  end

  def test_box2d_examples_check_and_lower
    idiomatic_example_paths.each do |path|
      program = MilkTea::ModuleLoader.check_program(path)

      assert_equal true, program.analyses_by_module_name.key?(module_name_for(path))
    end
  end

  def test_box2d_examples_build_with_host_compiler
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-box2d-idiomatic-examples") do |dir|
      idiomatic_example_paths.each do |path|
        basename = File.basename(path, ".mt")
        output_path = File.join(dir, basename)
        c_path = File.join(dir, "#{basename}.c")

        result = MilkTea::Build.build(path, output_path:, cc: compiler, keep_c_path: c_path)

        assert_equal File.expand_path(output_path), result.output_path, basename
        assert_equal File.expand_path(c_path), result.c_path, basename
        assert_includes result.link_flags, "-lraylib", basename
        assert_includes result.link_flags, "-lbox2d", basename
        assert File.exist?(output_path), "#{basename} did not produce an output binary"
        assert File.exist?(c_path), "#{basename} did not produce a C file"

        generated_c = File.read(c_path)
        assert_match(/#include "raylib\.h"/, generated_c, basename)
        assert_match(/#include "box2d\/box2d\.h"/, generated_c, basename)
      end
    end
  end

  private

  def idiomatic_example_paths
    [
      example_path("box2d_box_stack"),
      example_path("box2d_falling_box"),
    ]
  end

  def example_path(name)
    File.expand_path("../../examples/idiomatic/raylib/#{name}.mt", __dir__)
  end

  def module_name_for(path)
    relative_path = path.delete_prefix(File.expand_path("../../examples/", __dir__) + "/")
    "examples.#{relative_path.delete_suffix(".mt").tr("/", ".")}"
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
