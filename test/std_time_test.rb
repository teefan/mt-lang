# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaStdTimeTest < Minitest::Test
  def test_host_runtime_executes_time_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_time",
      "",
      "import std.mem.arena as arena",
      "import std.str as text",
      "import std.string as string",
      "import std.time as time",
      "",
      "def main() -> i32:",
      "    var scratch = arena.create(256)",
      "    defer scratch.release()",
      "    let formatted = time.format_utc(0, \"%Y-%m-%d\", addr(scratch))",
      "    if not formatted.is_ok:",
      "        return cast[i32](formatted.error)",
      "    var stamp = formatted.value",
      "    defer string.release(addr(stamp))",
      "    let view = string.as_str(stamp)",
      "    if not text.equal(view, \"1970-01-01\"):",
      "        return 10",
      "    if time.now_unix_seconds() <= 0:",
      "        return 11",
      "    let total = cast[i32](view.len) + 7",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 17, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-time") do |dir|
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
