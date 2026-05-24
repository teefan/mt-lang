# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMathRuntimeTest < Minitest::Test
  def test_host_runtime_executes_math_functions
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    Dir.mktmpdir("milk-tea-std-math") do |dir|
      source_path = File.join(dir, "std_math.mt")

      File.write(source_path, <<~MT

import std.math as math

const EPSILON: double = 0.000001

function approx(value: double, expected: double) -> bool:
    return math.abs(value - expected) <= EPSILON

function main() -> int:
    if approx(math.sqrt(9.0), 3.0) == false:
        return 1
    if approx(math.pow(2.0, 5.0), 32.0) == false:
        return 2
    if approx(math.exp(1.0), math.E) == false:
        return 3
    if approx(math.log(math.E), 1.0) == false:
        return 4
    if approx(math.log10(1000.0), 3.0) == false:
        return 5
    if approx(math.sin(math.HALF_PI), 1.0) == false:
        return 6
    if approx(math.cos(math.PI), -1.0) == false:
        return 7
    if approx(math.tan(0.0), 0.0) == false:
        return 8
    if approx(math.asin(1.0), math.HALF_PI) == false:
        return 9
    if approx(math.acos(-1.0), math.PI) == false:
        return 10
    if approx(math.atan(1.0), math.QUARTER_PI) == false:
        return 11
    if approx(math.atan2(1.0, 1.0), math.QUARTER_PI) == false:
        return 12
    if approx(math.floor(3.75), 3.0) == false:
        return 13
    if approx(math.ceil(3.25), 4.0) == false:
        return 14
    if approx(math.mod(7.5, 2.0), 1.5) == false:
        return 15
    if approx(math.abs(-4.5), 4.5) == false:
        return 16

    return 0

      MT

      )
      result = MilkTea::Run.run(source_path, cc: compiler)

      assert_equal "", result.stdout
      assert_equal "", result.stderr
      assert_equal 0, result.exit_status
      assert_nil result.output_path
      assert_nil result.c_path
      assert_equal compiler, result.compiler
      assert_equal ["-lm"], result.link_flags
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
