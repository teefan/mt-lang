# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdBytesTest < Minitest::Test
  def test_host_runtime_copies_owned_bytes_without_aliasing
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.bytes as bytes",
      "import std.maybe as maybe",
      "import std.str as text",
      "",
      "function main() -> int:",
      "    var source = array[ubyte, 3](65, 66, 67)",
      "    var owned = bytes.Bytes.copy(unsafe: span[ubyte](data = ptr_of(source[0]), len = 3))",
      "    defer owned.release()",
      "    source[0] = 90",
      "    let text_result = owned.as_str()",
      "    match text_result:",
      "        maybe.Maybe.none:",
      "            return 1",
      "        maybe.Maybe.some as payload:",
      "            if not payload.value.equal(\"ABC\"):",
      "                return 2",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_reports_invalid_utf8_for_owned_bytes
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "import std.bytes as bytes",
      "import std.maybe as maybe",
      "",
      "function main() -> int:",
      "    let empty = bytes.Bytes.empty()",
      "    if empty.as_span().len != 0:",
      "        return 1",
      "    var source = array[ubyte, 1](ubyte<-0xFF)",
      "    var owned = bytes.Bytes.copy(unsafe: span[ubyte](data = ptr_of(source[0]), len = 1))",
      "    defer owned.release()",
      "    let text_result = owned.as_str()",
      "    match text_result:",
      "        maybe.Maybe.none:",
      "            return 0",
      "        maybe.Maybe.some:",
      "            return 2",
      "    return 3",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-bytes") do |dir|
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
