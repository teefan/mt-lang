# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdStringTest < Minitest::Test
  def test_host_runtime_executes_owned_string_append_and_assign
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_string_append",
      "",
      "import std.string as string",
      "",
      "def byte_at(text: str, index: ptr_uint) -> int:",
      "    unsafe:",
      "        return int<-ubyte<-read(text.data + index)",
      "",
      "def main() -> int:",
      "    var name = string.String.from_str(\"Milk\")",
      "    defer name.release()",
      "",
      "    name.append(\" Tea\")",
      "    let view = name.as_str()",
      "    if view.len != 8:",
      "        return 1",
      "    if byte_at(view, 4) != 32:",
      "        return 2",
      "",
      "    name.assign(\"MT\")",
      "    let compact = name.as_str()",
      "    let total = int<-compact.len + byte_at(compact, 0) + byte_at(compact, 1)",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 163, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_owned_string_to_cstr
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_string_cstr",
      "",
      "import std.mem.arena as arena",
      "import std.string as string",
      "",
      "def cstr_len(text: cstr) -> int:",
      "    var count = 0",
      "    unsafe:",
      "        let data = ptr[char]<-text",
      "        while read(data + count) != zero[char]:",
      "            count += 1",
      "    return count",
      "",
      "def main() -> int:",
      "    var scratch = arena.create(64)",
      "    defer scratch.release()",
      "    var owned = string.String.from_str(\"abc\")",
      "    defer owned.release()",
      "",
      "    owned.append(\"def\")",
      "    let raw = owned.to_cstr(ref_of(scratch))",
      "    let length = cstr_len(raw)",
      "    return length",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 6, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_str_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_str_helpers",
      "",
      "import std.option as option",
      "import std.str as text",
      "",
      "def main() -> int:",
      "    let trimmed = text.trim_ascii_whitespace(\"  Milk Tea  \")",
      "    if not text.equal(trimmed, \"Milk Tea\"):",
      "        return 1",
      "    if not text.starts_with(trimmed, \"Milk\"):",
      "        return 2",
      "    if not text.ends_with(trimmed, \"Tea\"):",
      "        return 3",
      "    if not text.is_valid_utf8(trimmed):",
      "        return 4",
      "    let found = text.find_byte(trimmed, ubyte<-32)",
      "    return int<-trimmed.len + int<-option.unwrap[ptr_uint](found)",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 12, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_c_string_borrows
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_str_cstr_helpers",
      "",
      "import std.mem.arena as arena",
      "import std.str as text",
      "",
      "def main() -> int:",
      "    var scratch = arena.create(64)",
      "    defer scratch.release()",
      "    let raw = scratch.to_cstr(\"Milk Tea\")",
      "    let borrowed = text.cstr_as_str(raw)",
      "    var borrowed_chars: str = \"\"",
      "    unsafe:",
      "        borrowed_chars = text.chars_as_str(ptr[char]<-raw)",
      "    if not text.equal(borrowed, \"Milk Tea\"):",
      "        return 1",
      "    if not text.equal(borrowed_chars, borrowed):",
      "        return 2",
      "    return int<-borrowed.len + int<-borrowed_chars.len",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 16, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-string") do |dir|
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
