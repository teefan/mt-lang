# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdFmtLogTest < Minitest::Test
  def test_host_runtime_executes_basic_formatting
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_fmt",
      "",
      "import std.fmt as fmt",
      "import std.mem.arena as arena",
      "import std.string as string",
      "",
      "def byte_at(text: str, index: usize) -> i32:",
      "    unsafe:",
      "        return i32<-u8<-read(text.data + index)",
      "",
      "def main() -> i32:",
      "    var scratch = arena.create(64)",
      "    defer scratch.release()",
      "    var output = string.String.create()",
      "    defer output.release()",
      "",
      "    fmt.append_str(ref_of(output), \"n=\")",
      "    fmt.append_i32(ref_of(output), -42)",
      "    fmt.append_str(ref_of(output), \" ok=\")",
      "    fmt.append_bool(ref_of(output), true)",
      "    fmt.append_str(ref_of(output), \" size=\")",
      "    fmt.append_usize(ref_of(output), 17)",
      "    fmt.append_str(ref_of(output), \" u=\")",
      "    fmt.append_u32(ref_of(output), u32<-7)",
      "    fmt.append_str(ref_of(output), \" tail=\")",
      "    fmt.append_cstr(ref_of(output), scratch.to_cstr(\" raw\"))",
      "",
      "    let view = output.as_str()",
      "    if view.len != 35:",
      "        return 1",
      "    let total = i32<-view.len + byte_at(view, 34)",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 154, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_stderr_logging
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_log",
      "",
      "import std.log as log",
      "",
      "def main() -> i32:",
      "    if not log.info(\"ready\"):",
      "        return 1",
      "    if not log.warn(\"careful\"):",
      "        return 2",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "[info] ready\n[warn] careful\n", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_fmt_string_format_literals
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_fmt_string",
      "",
      "import std.fmt as fmt",
      "import std.mem.arena as arena",
      "import std.string as string",
      "",
      "def main() -> i32:",
      "    var scratch = arena.create(64)",
      "    defer scratch.release()",
      "    let delta: i16 = -42",
      "    let small: u8 = 7",
      "    let ticks: u64 = 9",
      "    var output = fmt.string(f\"n=\#{delta} ok=\#{true} small=\#{small} ticks=\#{ticks} raw=\#{scratch.to_cstr(\"wow\")}\")",
      "    let total = i32<-output.count()",
      "    defer output.release()",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 37, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_float_format_literals
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_fmt_float_string",
      "",
      "import std.fmt as fmt",
      "import std.io as io",
      "import std.string as string",
      "",
      "def main() -> i32:",
      "    let ratio: f32 = 2.5",
      "    let scale: f64 = 0.125",
      "    var output = fmt.string(f\"ratio=\#{ratio} scale=\#{scale}\")",
      "    defer output.release()",
      "    if not io.println(output.as_str()):",
      "        return 1",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "ratio=2.5 scale=0.125\n", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_general_format_string_expressions
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_fmt_general_expr",
      "",
      "import std.io as io",
      "",
      "def size(text: str) -> usize:",
      "    return text.len",
      "",
      "def main() -> i32:",
      "    let count = 7",
      "    let text = f\"count=\#{count}\"",
      "    if size(f\"ok=\#{true}\") == 0:",
      "        return 1",
      "    if not io.println(text):",
      "        return 2",
      "    return i32<-text.len",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "count=7\n", result.stdout
    assert_equal "", result.stderr
    assert_equal 7, result.exit_status
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
