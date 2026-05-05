# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdJsonTest < Minitest::Test
  def test_host_runtime_executes_json_lexer
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_json_lexer",
      "",
      "import std.json as json",
      "",
      "def take(lexer: ref[json.Lexer], kind: json.TokenKind) -> int:",
      "    let item = json.next(lexer)",
      "    if not item.is_ok:",
      "        return 100 + int<-item.error",
      "    if item.value.kind != kind:",
      "        return 50 + int<-item.value.kind",
      "    return int<-kind",
      "",
      "def main() -> int:",
      "    var lexer = json.create(\"{ \\\"a\\\": [true, false, null, -12.5e+2] }\")",
      "    var total = 0",
      "    total += take(ref_of(lexer), json.left_brace())",
      "    total += take(ref_of(lexer), json.string_value())",
      "    total += take(ref_of(lexer), json.colon())",
      "    total += take(ref_of(lexer), json.left_bracket())",
      "    total += take(ref_of(lexer), json.true_value())",
      "    total += take(ref_of(lexer), json.comma())",
      "    total += take(ref_of(lexer), json.false_value())",
      "    total += take(ref_of(lexer), json.comma())",
      "    total += take(ref_of(lexer), json.null_value())",
      "    total += take(ref_of(lexer), json.comma())",
      "    total += take(ref_of(lexer), json.number_value())",
      "    total += take(ref_of(lexer), json.right_bracket())",
      "    total += take(ref_of(lexer), json.right_brace())",
      "    total += take(ref_of(lexer), json.eof())",
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
      "def main() -> int:",
      "    var output = string.String.create()",
      "    defer output.release()",
      "    json.append_string(ref_of(output), \"a\\nb\")",
      "    json.append_bool(ref_of(output), true)",
      "    json.append_int(ref_of(output), -7)",
      "    let view = output.as_str()",
      "    if view.len != 12:",
      "        return 1",
      "    if text.byte_at(view, 2) != ubyte<-92:",
      "        return 2",
      "    if text.byte_at(view, 3) != ubyte<-110:",
      "        return 3",
      "    if text.byte_at(view, 5) != ubyte<-34:",
      "        return 4",
      "    let total = int<-view.len + int<-(text.byte_at(view, 3) - ubyte<-100) + int<-(text.byte_at(view, 11) - ubyte<-50)",
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
