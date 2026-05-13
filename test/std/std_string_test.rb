# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdStringTest < Minitest::Test
  def test_host_runtime_executes_owned_string_storage_methods
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_string_storage",
      "",
      "import std.string as string",
      "",
      "function byte_at(text: str, index: ptr_uint) -> int:",
      "    unsafe:",
      "        return int<-ubyte<-read(text.data + index)",
      "",
      "function main() -> int:",
      "    var text = string.String.with_capacity(2)",
      "    defer text.release()",
      "    if text.capacity() < 2:",
      "        return 1",
      "    if not text.is_empty():",
      "        return 2",
      "",
      "    text.push_byte(65)",
      "    text.push_byte(66)",
      "    text.push_byte(67)",
      "    if text.len() != 3:",
      "        return 3",
      "    if text.capacity() < 3:",
      "        return 4",
      "",
      "    let view = text.as_str()",
      "    if byte_at(view, 0) != 65 or byte_at(view, 2) != 67:",
      "        return 5",
      "",
      "    text.clear()",
      "    if not text.is_empty():",
      "        return 6",
      "",
      "    text.reserve(32)",
      "    if text.capacity() < 32:",
      "        return 7",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_owned_string_append_and_assign
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_string_append",
      "",
      "import std.string as string",
      "",
      "function byte_at(text: str, index: ptr_uint) -> int:",
      "    unsafe:",
      "        return int<-ubyte<-read(text.data + index)",
      "",
      "function main() -> int:",
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

  def test_host_runtime_executes_owned_string_self_append_on_growth
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_string_self_append",
      "",
      "import std.str as text",
      "import std.string as string",
      "",
      "function main() -> int:",
      "    var value = string.String.from_str(\"abc\")",
      "    defer value.release()",
      "",
      "    let full = value.as_str()",
      "    value.append(full)",
      "    if not value.as_str().equal(\"abcabc\"):",
      "        return 1",
      "",
      "    let middle = value.as_str().slice(1, 4)",
      "    value.append(middle)",
      "    if not value.as_str().equal(\"abcabcbcab\"):",
      "        return 2",
      "",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
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
      "function cstr_len(text: cstr) -> int:",
      "    var count = 0",
      "    unsafe:",
      "        let data = ptr[char]<-text",
      "        while read(data + count) != zero[char]:",
      "            count += 1",
      "    return count",
      "",
      "function main() -> int:",
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

  def test_host_runtime_rejects_invalid_utf8_owned_string_as_str
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_string_invalid_utf8",
      "",
      "import std.string as string",
      "",
      "function main() -> int:",
      "    var value = string.String.create()",
      "    defer value.release()",
      "    value.push_byte(ubyte<-0xFF)",
      "    let borrowed = value.as_str()",
      "    return int<-borrowed.len",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal 134, result.exit_status
    assert_match(/string\.as_str text must be valid UTF-8/, result.stderr)
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_str_helpers
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_str_helpers",
      "",
      "import std.maybe as maybe",
      "import std.str as text",
      "",
      "function main() -> int:",
      "    let trimmed = \"  Milk Tea  \".trim_ascii_whitespace()",
      "    if not trimmed.equal(\"Milk Tea\"):",
      "        return 1",
      "    if not trimmed.starts_with(\"Milk\"):",
      "        return 2",
      "    if not trimmed.ends_with(\"Tea\"):",
      "        return 3",
      "    if not trimmed.is_valid_utf8():",
      "        return 4",
      "    let found = trimmed.find_byte(ubyte<-32)",
      "    match found:",
      "        maybe.Maybe.none:",
      "            return 5",
      "        maybe.Maybe.some as payload:",
      "            return int<-trimmed.len + int<-payload.value",
      "    return 5",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 12, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_str_equality_operators
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_str_equality_ops",
      "",
      "import std.mem.arena as arena",
      "import std.str as text",
      "",
      "function main() -> int:",
      "    var scratch = arena.create(64)",
      "    defer scratch.release()",
      "",
      "    let left = text.cstr_as_str(scratch.to_cstr(\"Milk Tea\"))",
      "    let right = text.cstr_as_str(scratch.to_cstr(\"Milk Tea\"))",
      "    let other = text.cstr_as_str(scratch.to_cstr(\"Tea\"))",
      "",
      "    if left != right:",
      "        return 1",
      "    if not (left == right):",
      "        return 2",
      "    if left == other:",
      "        return 3",
      "    if not (left != other):",
      "        return 4",
      "",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
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
      "function main() -> int:",
      "    var scratch = arena.create(64)",
      "    defer scratch.release()",
      "    let raw = scratch.to_cstr(\"Milk Tea\")",
      "    let borrowed = text.cstr_as_str(raw)",
      "    var borrowed_chars: str = \"\"",
      "    unsafe:",
      "        borrowed_chars = text.chars_as_str(ptr[char]<-raw)",
      "    if not borrowed.equal(\"Milk Tea\"):",
      "        return 1",
      "    if not borrowed_chars.equal(borrowed):",
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
