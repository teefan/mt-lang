# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaStdIdiomaticExamplesTest < Minitest::Test
  def test_idiomatic_examples_use_curated_surface_only
    idiomatic_example_paths.each do |path|
      source = File.read(path)

      assert_match(/^module examples\.idiomatic\.std\./, source)
      assert_match(/^import std\./, source)
      refute_match(/^import std\.c\./, source)
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

  def test_io_printing_example_runs
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    result = MilkTea::Run.run(example_path("io_printing"), cc: compiler)

    assert_equal "stdout raw -> Milk Tea\nstdout fmt -> count=7 ok=true angle=45.5 ratio=0.25\n", result.stdout
    assert_equal "stderr raw -> warning path\nstderr fmt -> count=7 angle=45.5 ratio=0.25\n", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_io_printing_example_generated_c_inlines_formatted_condition_calls
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-io-printing") do |dir|
      output_path = File.join(dir, "io_printing")
      c_path = File.join(dir, "io_printing.c")

      MilkTea::Build.build(example_path("io_printing"), output_path:, keep_c_path: c_path, cc: compiler)

      generated_c = File.read(c_path)

      assert_match(/if \(!std_io_write\(\(mt_str\)\{ \.data = "stdout raw -> ", \.len = 14 \}\)\) \{/, generated_c)
      assert_match(/if \(!std_io_write_line\(\(mt_str\)\{ \.data = "Milk Tea", \.len = 8 \}\)\) \{/, generated_c)
      assert_match(/std_string_String __mt_fmt_string_\d+ = examples_idiomatic_std_io_printing__fmt_\d+\(count, true, angle, ratio\);/, generated_c)
      assert_match(/std_string_String __mt_fmt_string_\d+ = examples_idiomatic_std_io_printing__fmt_\d+\(count, angle, ratio\);/, generated_c)
      assert_match(/if \(!std_io_println_formatted\(&__mt_fmt_string_\d+\)\) \{/, generated_c)
      assert_match(/if \(!std_io_write_error_line_formatted\(&__mt_fmt_string_\d+\)\) \{/, generated_c)
      refute_match(/static bool std_io_print\(mt_str text\)/, generated_c)
      refute_match(/static bool std_io_println\(mt_str text\)/, generated_c)
      refute_match(/std_fmt_append\(&__mt_fmt_string_\d+/, generated_c)
      refute_match(/bool __mt_println_formatted_\d+ = std_io_println_formatted/, generated_c)
      refute_match(/bool __mt_write_error_line_formatted_\d+ = std_io_write_error_line_formatted/, generated_c)
    end
  end

  private

  def idiomatic_example_paths
    Dir[File.expand_path("../examples/idiomatic/std/*.mt", __dir__)].sort
  end

  def example_path(name)
    File.expand_path("../examples/idiomatic/std/#{name}.mt", __dir__)
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
