# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdRaylibRuntimeTest < Minitest::Test
  def test_host_runtime_executes_env_flag_without_raw_cstr_inputs
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_raylib_runtime",
      "",
      "import std.raylib.runtime as runtime",
      "",
      "function main() -> int:",
      "    if not runtime.env_flag(\"PATH\"):",
      "        return 1",
      "    if runtime.env_flag(\"MILK_TEA_ENV_FLAG_SHOULD_NOT_EXIST_9A77E9\"):",
      "        return 2",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_nil result.output_path
    assert_nil result.c_path
    assert_equal compiler, result.compiler
    assert_equal [], result.link_flags
  end

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-raylib-runtime") do |dir|
      source_path = File.join(dir, "program.mt")
      File.write(source_path, source)
      return MilkTea::Run.run(source_path, cc: compiler)
    end
  end

  def compiler_available?(compiler)
    return File.executable?(compiler) if compiler.include?(File::SEPARATOR)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |entry|
      candidate = File.join(entry, compiler)
      File.file?(candidate) && File.executable?(candidate)
    end
  end
end
