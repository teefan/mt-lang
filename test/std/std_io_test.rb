# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdIoTest < Minitest::Test
  def test_host_runtime_executes_stdout_printing
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_io",
      "",
      "import std.io as io",
      "",
      "def main() -> int:",
      "    if not io.print(\"Milk\"):",
      "        return 1",
      "    if not io.println(\" Tea\"):",
      "        return 2",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "Milk Tea\n", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_stdout_format_printing
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_io_fmt",
      "",
      "import std.io as io",
      "",
      "def main() -> int:",
      "    let count: short = -42",
      "    let ticks: ulong = 9",
      "    if not io.print(f\"count=\#{count} ok=\#{true} ticks=\#{ticks}\"):",
      "        return 1",
      "    if not io.println(f\" done=\#{ubyte<-7}\"):",
      "        return 2",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "count=-42 ok=true ticks=9 done=7\n", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_stdout_float_format_printing
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_io_float_fmt",
      "",
      "import std.io as io",
      "",
      "def main() -> int:",
      "    let angle: float = 45.5",
      "    let ratio: double = 0.25",
      "    if not io.println(f\"angle=\#{angle} ratio=\#{ratio}\"):",
      "        return 1",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "angle=45.5 ratio=0.25\n", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_stderr_format_printing
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_io_error_fmt",
      "",
      "import std.io as io",
      "",
      "def main() -> int:",
      "    let ratio: double = 0.25",
      "    if not io.write_error(f\"warn=\#{true}\"):",
      "        return 1",
      "    if not io.write_error_line(f\" ratio=\#{ratio} count=\#{ubyte<-7}\"):",
      "        return 2",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "warn=true ratio=0.25 count=7\n", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_stderr_printing
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_io_error",
      "",
      "import std.io as io",
      "",
      "def main() -> int:",
      "    if not io.write_error(\"warn\"):",
      "        return 1",
      "    if not io.write_error_line(\"ing\"):",
      "        return 2",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "warning\n", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-io") do |dir|
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
