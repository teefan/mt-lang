# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMathTest < Minitest::Test
  def test_host_runtime_executes_integer_std_math_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_math_int",
      "",
      "import std.math as math",
      "",
      "def main() -> int:",
      "    let low = math.min(9, 4)",
      "    let high = math.max(9, 4)",
      "    let clamped = math.clamp(42, 0, 40)",
      "    let distance = math.abs(-8)",
      "    return low + high + clamped + distance",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 61, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_float_std_math_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_math_float",
      "",
      "import std.math as math",
      "",
      "def main() -> int:",
      "    let low = math.min(math.pi, math.tau)",
      "    let high = math.max(math.pi, math.tau)",
      "    let halfway = math.lerp(math.pi, math.tau, 0.5)",
      "    let clamped = math.clamp(halfway, math.pi, math.tau)",
      "    let delta = math.abs(clamped - 4.712389)",
      "    if low == math.pi and high == math.tau and delta < 0.01:",
      "        return 0",
      "    return 1",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_std_c_libm_double_surface
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_c_libm",
      "",
      "import std.c.libm as math",
      "",
      "def main() -> int:",
      "    let sine = math.sin(math.M_PI * 0.5)",
      "    if sine < 0.999 or sine > 1.001:",
      "        return 10",
      "    if math.sqrt(81.0) != 9.0:",
      "        return 11",
      "    if math.floor(2.75) != 2.0:",
      "        return 12",
      "    if math.M_PI_F < 3.14 or math.M_PI_F > 3.15:",
      "        return 13",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal ["-lm"], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-math") do |dir|
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
