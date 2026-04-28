# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaStdFmtLogTest < Minitest::Test
  def test_host_runtime_executes_basic_formatting
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_fmt",
      "",
      "import std.fmt as fmt",
      "import std.string as string",
      "",
      "def byte_at(text: str, index: usize) -> i32:",
      "    unsafe:",
      "        return cast[i32](cast[u8](deref(text.data + index)))",
      "",
      "def main() -> i32:",
      "    var output = string.create()",
      "    defer string.release(addr(output))",
      "",
      "    fmt.append_str(addr(output), \"n=\")",
      "    fmt.append_i32(addr(output), -42)",
      "    fmt.append_str(addr(output), \" ok=\")",
      "    fmt.append_bool(addr(output), true)",
      "    fmt.append_str(addr(output), \" size=\")",
      "    fmt.append_usize(addr(output), 17)",
      "",
      "    let view = string.as_str(output)",
      "    if view.len != 21:",
      "        return 1",
      "    let total = cast[i32](view.len) + byte_at(view, 20)",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 76, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_stdout_logging
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_log",
      "",
      "import std.log as log",
      "import std.mem.arena as arena",
      "",
      "def main() -> i32:",
      "    var scratch = arena.create(128)",
      "    defer scratch.release()",
      "    if not log.info(\"ready\", addr(scratch)):",
      "        return 1",
      "    if not log.warn(\"careful\", addr(scratch)):",
      "        return 2",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "[info] ready\n[warn] careful\n", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-fmt-log") do |dir|
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
