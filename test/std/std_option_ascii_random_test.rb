# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdMaybeAsciiRandomTest < Minitest::Test
  def test_host_runtime_executes_maybe_and_ascii_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_maybe_ascii",
      "",
      "import std.ascii as ascii",
      "import std.maybe as maybe",
      "",
      "def main() -> int:",
      "    let number: maybe.Maybe[int] = maybe.Maybe[int].some(value= 37)",
      "    if not maybe.is_some(number):",
      "        return 1",
      "    let digit = ascii.digit_value(ubyte<-55)",
      "    let hex = ascii.hex_digit_value(ubyte<-70)",
      "    if not ascii.is_ident_start(ubyte<-95):",
      "        return 2",
      "    if ascii.to_lower(ubyte<-65) != ubyte<-97:",
      "        return 3",
      "    match number:",
      "        maybe.Maybe.none:",
      "            return 4",
      "        maybe.Maybe.some as payload:",
      "            return payload.value + digit + hex",
      "    return 5",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 59, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_deterministic_random_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_random",
      "",
      "import std.random as random",
      "",
      "def main() -> int:",
      "    var left = random.create(1234)",
      "    var right = random.create(1234)",
      "    let first = random.next_ulong(ref_of(left))",
      "    let repeat = random.next_ulong(ref_of(right))",
      "    if first != repeat:",
      "        return 1",
      "    let ranged = random.range_int(ref_of(left), 10, 20)",
      "    if ranged < 10 or ranged > 20:",
      "        return 2",
      "    let bounded = random.range_ptr_uint(ref_of(left), 7)",
      "    if bounded >= 7:",
      "        return 3",
      "    return ranged + int<-bounded",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_operator result.exit_status, :>=, 10
    assert_operator result.exit_status, :<=, 26
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-maybe-ascii-random") do |dir|
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
