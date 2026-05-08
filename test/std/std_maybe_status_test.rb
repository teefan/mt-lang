# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMaybeStatusTest < Minitest::Test
  def test_host_runtime_executes_maybe_and_status_variants
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_maybe_status",
      "",
      "import std.maybe as maybe",
      "import std.status as status",
      "",
      "function maybe_score(value: maybe.Maybe[int]) -> int:",
      "    match value:",
      "        maybe.Maybe.none:",
      "            return 1",
      "        maybe.Maybe.some as payload:",
      "            return payload.value",
      "    return 1",
      "",
      "function status_score(value: status.Status[int, int]) -> int:",
      "    match value:",
      "        status.Status.err as payload:",
      "            return payload.error",
      "        status.Status.ok as payload:",
      "            return payload.value",
      "    return 0",
      "",
      "function main() -> int:",
      "    let empty: maybe.Maybe[int] = maybe.Maybe[int].none",
      "    let seeded: maybe.Maybe[int] = maybe.Maybe[int].some(value= 40)",
      "    let ok_value: status.Status[int, int] = status.Status[int, int].ok(value= 2)",
      "    let err_value: status.Status[int, int] = status.Status[int, int].err(error= 3)",
      "    if not maybe.is_some(seeded):",
      "        return 100",
      "    if maybe.value_or(empty, 7) != 7:",
      "        return 101",
      "    if maybe_score(empty) != 1:",
      "        return 102",
      "    if maybe_score(seeded) != 40:",
      "        return 103",
      "    if not status.is_ok(ok_value):",
      "        return 104",
      "    if status.value_or(err_value, 9) != 9:",
      "        return 105",
      "    match seeded:",
      "        maybe.Maybe.none:",
      "            return 106",
      "        maybe.Maybe.some as payload:",
      "            return payload.value + status_score(ok_value) + status_score(err_value)",
      "    return 106",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 45, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-maybe-status") do |dir|
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
