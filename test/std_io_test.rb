# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaStdIoTest < Minitest::Test
  def test_host_runtime_executes_stdout_printing
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_io",
      "",
      "import std.io as io",
      "import std.mem.arena as arena",
      "",
      "def main() -> i32:",
      "    var scratch = arena.create(128)",
      "    defer scratch.release()",
      "",
      "    if not io.print(\"Milk\", addr(scratch)):",
      "        return 1",
      "    if not io.println(\" Tea\", addr(scratch)):",
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

  def test_host_runtime_executes_stderr_printing
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_io_error",
      "",
      "import std.io as io",
      "",
      "def main() -> i32:",
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
