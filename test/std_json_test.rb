# frozen_string_literal: true

require "tmpdir"
require_relative "test_helper"

class MilkTeaStdJsonTest < Minitest::Test
  def test_host_runtime_executes_json_lexer
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_json_lexer",
      "",
      "import std.json as json",
      "",
      "def take(lexer: ref[json.Lexer], kind: json.TokenKind) -> i32:",
      "    let item = json.next(lexer)",
      "    if not item.is_ok:",
      "        return 100 + cast[i32](item.error)",
      "    if item.value.kind != kind:",
      "        return 50 + cast[i32](item.value.kind)",
      "    return cast[i32](kind)",
      "",
      "def main() -> i32:",
      "    var lexer = json.create(\"{ \\\"a\\\": [true, false, null, -12.5e+2] }\")",
      "    var total = 0",
      "    total += take(addr(lexer), json.left_brace())",
      "    total += take(addr(lexer), json.string_value())",
      "    total += take(addr(lexer), json.colon())",
      "    total += take(addr(lexer), json.left_bracket())",
      "    total += take(addr(lexer), json.true_value())",
      "    total += take(addr(lexer), json.comma())",
      "    total += take(addr(lexer), json.false_value())",
      "    total += take(addr(lexer), json.comma())",
      "    total += take(addr(lexer), json.null_value())",
      "    total += take(addr(lexer), json.comma())",
      "    total += take(addr(lexer), json.number_value())",
      "    total += take(addr(lexer), json.right_bracket())",
      "    total += take(addr(lexer), json.right_brace())",
      "    total += take(addr(lexer), json.eof())",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 90, result.exit_status
    assert_equal [], result.link_flags
  end

  def test_host_runtime_executes_json_writer
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_json_writer",
      "",
      "import std.json as json",
      "import std.str as text",
      "import std.string as string",
      "",
      "def main() -> i32:",
      "    var output = string.String.create()",
      "    defer output.release()",
      "    json.append_string(addr(output), \"a\\nb\")",
      "    json.append_bool(addr(output), true)",
      "    json.append_i32(addr(output), -7)",
      "    let view = output.as_str()",
      "    if view.len != 12:",
      "        return 1",
      "    if text.byte_at(view, 2) != cast[u8](92):",
      "        return 2",
      "    if text.byte_at(view, 3) != cast[u8](110):",
      "        return 3",
      "    if text.byte_at(view, 5) != cast[u8](34):",
      "        return 4",
      "    let total = cast[i32](view.len) + cast[i32](text.byte_at(view, 3) - cast[u8](100)) + cast[i32](text.byte_at(view, 11) - cast[u8](50))",
      "    return total",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 27, result.exit_status
    assert_equal [], result.link_flags
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-json") do |dir|
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
