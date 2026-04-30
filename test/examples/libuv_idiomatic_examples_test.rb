# frozen_string_literal: true

require_relative "../test_helper"

class MilkTeaLibuvIdiomaticExamplesTest < Minitest::Test
  def test_idiomatic_examples_use_curated_surface_only
    idiomatic_example_paths.each do |path|
      source = File.read(path)

      assert_match(/^module examples\.idiomatic\.libuv\./, source)
      assert_match(/^import std\.async as async$/, source)
      refute_match(/^import std\.c\.libuv as /, source)
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

  def test_async_await_example_runs
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    result = MilkTea::Run.run(example_path("async_await"), cc: compiler)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 42, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_async_fan_out_example_runs
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    result = MilkTea::Run.run(example_path("async_fan_out"), cc: compiler)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 43, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_async_timer_overlap_example_runs
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    result = MilkTea::Run.run(example_path("async_timer_overlap"), cc: compiler)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 42, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  def test_async_latest_showcase_example_runs
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    result = MilkTea::Run.run(example_path("async_latest_showcase"), cc: compiler)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 18, result.exit_status
    assert_includes result.link_flags, "-luv"
  end

  private

  def idiomatic_example_paths
    Dir[File.expand_path("../../examples/idiomatic/libuv/*.mt", __dir__)].sort
  end

  def example_path(name)
    File.expand_path("../../examples/idiomatic/libuv/#{name}.mt", __dir__)
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
