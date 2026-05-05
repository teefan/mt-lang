# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdEasingTest < Minitest::Test
  def test_host_runtime_executes_std_easing_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_easing",
      "",
      "import std.easing as ease",
      "import std.math as math",
      "",
      "def approx_eq(a: float, b: float) -> bool:",
      "    return math.abs(a - b) < 0.001",
      "",
      "def main() -> int:",
      "    if not approx_eq(ease.none(5.0, 10.0, 20.0, 10.0), 10.0):",
      "        return 20",
      "    if not approx_eq(ease.linear_none(5.0, 10.0, 20.0, 10.0), 20.0):",
      "        return 21",
      "    if not approx_eq(ease.linear_in(5.0, 10.0, 20.0, 10.0), 20.0):",
      "        return 1",
      "    if not approx_eq(ease.linear_out(5.0, 10.0, 20.0, 10.0), 20.0):",
      "        return 22",
      "    if not approx_eq(ease.linear_in_out(5.0, 10.0, 20.0, 10.0), 20.0):",
      "        return 23",
      "    if not approx_eq(ease.quad_in(5.0, 0.0, 100.0, 10.0), 25.0):",
      "        return 24",
      "    if not approx_eq(ease.quad_out(5.0, 0.0, 100.0, 10.0), 75.0):",
      "        return 2",
      "    if not approx_eq(ease.quad_in_out(5.0, 0.0, 100.0, 10.0), 50.0):",
      "        return 25",
      "    if not approx_eq(ease.cubic_in(5.0, 0.0, 100.0, 10.0), 12.5):",
      "        return 26",
      "    if not approx_eq(ease.cubic_out(5.0, 0.0, 100.0, 10.0), 87.5):",
      "        return 3",
      "    if not approx_eq(ease.cubic_in_out(5.0, 0.0, 100.0, 10.0), 50.0):",
      "        return 27",
      "    if not approx_eq(ease.sine_in(10.0, 0.0, 1.0, 10.0), 1.0):",
      "        return 28",
      "    if not approx_eq(ease.sine_out(5.0, 0.0, 1.0, 10.0), 0.70710677):",
      "        return 4",
      "    if not approx_eq(ease.sine_in_out(5.0, 0.0, 1.0, 10.0), 0.5):",
      "        return 29",
      "    if not approx_eq(ease.circ_in(10.0, 0.0, 100.0, 10.0), 100.0):",
      "        return 30",
      "    if not approx_eq(ease.circ_out(5.0, 0.0, 100.0, 10.0), 86.60254):",
      "        return 5",
      "    if not approx_eq(ease.circ_in_out(5.0, 0.0, 100.0, 10.0), 50.0):",
      "        return 31",
      "    if not approx_eq(ease.expo_in(0.0, 2.0, 10.0, 20.0), 2.0):",
      "        return 32",
      "    if not approx_eq(ease.expo_out(20.0, 2.0, 10.0, 20.0), 12.0):",
      "        return 33",
      "    if not approx_eq(ease.expo_in_out(20.0, 2.0, 10.0, 20.0), 12.0):",
      "        return 34",
      "    if not approx_eq(ease.back_in(0.0, 2.0, 10.0, 20.0), 2.0):",
      "        return 35",
      "    if not approx_eq(ease.back_out(20.0, 2.0, 10.0, 20.0), 12.0):",
      "        return 36",
      "    if not approx_eq(ease.back_in_out(20.0, 2.0, 10.0, 20.0), 12.0):",
      "        return 37",
      "    if not approx_eq(ease.bounce_out(10.0, 0.0, 100.0, 10.0), 100.0):",
      "        return 6",
      "    if not approx_eq(ease.bounce_in(0.0, 2.0, 10.0, 20.0), 2.0):",
      "        return 38",
      "    if not approx_eq(ease.bounce_in_out(20.0, 2.0, 10.0, 20.0), 12.0):",
      "        return 39",
      "    if not approx_eq(ease.elastic_in(0.0, 2.0, 10.0, 20.0), 2.0):",
      "        return 7",
      "    if not approx_eq(ease.elastic_out(20.0, 2.0, 10.0, 20.0), 12.0):",
      "        return 8",
      "    if not approx_eq(ease.elastic_in_out(20.0, 2.0, 10.0, 20.0), 12.0):",
      "        return 40",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_includes result.link_flags, "-lm"
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-easing") do |dir|
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
