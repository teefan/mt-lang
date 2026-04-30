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

  def test_async_asset_loading_example_builds
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-raylib-async-asset") do |dir|
      output_path = File.join(dir, "async_asset_loading")
      c_path = File.join(dir, "async_asset_loading.c")

      result = MilkTea::Build.build(example_path("async_asset_loading"), output_path:, cc: compiler, keep_c_path: c_path)

      assert_equal File.expand_path(output_path), result.output_path
      assert_equal File.expand_path(c_path), result.c_path
      assert_includes result.link_flags, "-lraylib"
      assert_includes result.link_flags, "-luv"
    end
  end

  private

  def idiomatic_example_paths
    Dir[File.expand_path("../examples/idiomatic/raylib/*.mt", __dir__)].sort
  end

  def example_path(name)
    File.expand_path("../examples/idiomatic/raylib/#{name}.mt", __dir__)
  end

  def module_name_for(path)
    relative_path = path.delete_prefix(File.expand_path("../examples/", __dir__) + "/")
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
