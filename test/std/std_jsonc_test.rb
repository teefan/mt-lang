# frozen_string_literal: true

require "tmpdir"
require_relative "../test_helper"

class MilkTeaStdJsoncTest < Minitest::Test
  def test_host_runtime_parses_jsonc_via_cjson_wrapper
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_jsonc_parse",
      "",
      "import std.cjson as cjson",
      "import std.jsonc as jsonc",
      "import std.str as text",
      "",
      "def main() -> int:",
      "    let parsed_result = jsonc.parse(<<-JSONC",
      "        {",
      "            // name comment",
      "            \"name\": \"demo\",",
      "            \"values\": [1, 2,],",
      "            \"enabled\": true,",
      "        }",
      "    JSONC",
      "    )",
      "    if not parsed_result.is_ok:",
      "        return 100 + int<-parsed_result.error",
      "",
      "    let root = parsed_result.value",
      "    defer cjson.delete(root)",
      "",
      "    let name = cjson.get_object_item(root, \"name\")",
      "    if name == null:",
      "        return 1",
      "    if int<-cjson.is_string(name) == 0:",
      "        return 1",
      "    let name_value = cjson.get_string_value(name)",
      "    if name_value == null or not text.equal(text.cstr_as_str(name_value), \"demo\"):",
      "        return 2",
      "",
      "    let values = cjson.get_object_item(root, \"values\")",
      "    if values == null:",
      "        return 3",
      "    if int<-cjson.is_array(values) == 0:",
      "        return 3",
      "    if cjson.get_array_size(values) != 2:",
      "        return 4",
      "",
      "    let enabled = cjson.get_object_item(root, \"enabled\")",
      "    if enabled == null:",
      "        return 5",
      "    if int<-cjson.is_true(enabled) == 0:",
      "        return 5",
      "",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  def test_host_runtime_reports_jsonc_parse_failure
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_jsonc_parse_error",
      "",
      "import std.jsonc as jsonc",
      "",
      "def main() -> int:",
      "    let result = jsonc.parse(\"{ nope }\")",
      "    if result.is_ok:",
      "        return 1",
      "    return int<-result.error",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 3, result.exit_status
  end

  def test_host_runtime_normalizes_jsonc_for_json_lexer
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_jsonc_normalize",
      "",
      "import std.json as json",
      "import std.jsonc as jsonc",
      "import std.str as text",
      "import std.string as string",
      "",
      "def take_kind(lexer: ref[json.Lexer], kind: json.TokenKind, code: int) -> int:",
      "    let item = json.next(lexer)",
      "    if not item.is_ok:",
      "        return code",
      "    if item.value.kind != kind:",
      "        return code",
      "    return 0",
      "",
      "def take_text(lexer: ref[json.Lexer], kind: json.TokenKind, expected: str, code: int) -> int:",
      "    let item = json.next(lexer)",
      "    if not item.is_ok:",
      "        return code",
      "    if item.value.kind != kind:",
      "        return code",
      "    if not text.equal(item.value.text, expected):",
      "        return code",
      "    return 0",
      "",
      "def main() -> int:",
      "    let normalized_result = jsonc.normalize(<<-JSONC",
      "        {",
      "            // name comment",
      "            \"name\": \"demo//literal\",",
      "            \"values\": [1, 2,],",
      "            /* enabled comment */",
      "            \"enabled\": true,",
      "        }",
      "    JSONC",
      "    )",
      "    if not normalized_result.is_ok:",
      "        return 100 + int<-normalized_result.error",
      "",
      "    var normalized = normalized_result.value",
      "    defer normalized.release()",
      "",
      "    var lexer = json.create(normalized.as_str())",
      "    var status = take_kind(ref_of(lexer), json.left_brace(), 1)",
      "    if status != 0:",
      "        return status",
      "    status = take_text(ref_of(lexer), json.string_value(), \"name\", 2)",
      "    if status != 0:",
      "        return status",
      "    status = take_kind(ref_of(lexer), json.colon(), 3)",
      "    if status != 0:",
      "        return status",
      "    status = take_text(ref_of(lexer), json.string_value(), \"demo//literal\", 4)",
      "    if status != 0:",
      "        return status",
      "    status = take_kind(ref_of(lexer), json.comma(), 5)",
      "    if status != 0:",
      "        return status",
      "    status = take_text(ref_of(lexer), json.string_value(), \"values\", 6)",
      "    if status != 0:",
      "        return status",
      "    status = take_kind(ref_of(lexer), json.colon(), 7)",
      "    if status != 0:",
      "        return status",
      "    status = take_kind(ref_of(lexer), json.left_bracket(), 8)",
      "    if status != 0:",
      "        return status",
      "    status = take_text(ref_of(lexer), json.number_value(), \"1\", 9)",
      "    if status != 0:",
      "        return status",
      "    status = take_kind(ref_of(lexer), json.comma(), 10)",
      "    if status != 0:",
      "        return status",
      "    status = take_text(ref_of(lexer), json.number_value(), \"2\", 11)",
      "    if status != 0:",
      "        return status",
      "    status = take_kind(ref_of(lexer), json.right_bracket(), 12)",
      "    if status != 0:",
      "        return status",
      "    status = take_kind(ref_of(lexer), json.comma(), 13)",
      "    if status != 0:",
      "        return status",
      "    status = take_text(ref_of(lexer), json.string_value(), \"enabled\", 14)",
      "    if status != 0:",
      "        return status",
      "    status = take_kind(ref_of(lexer), json.colon(), 15)",
      "    if status != 0:",
      "        return status",
      "    status = take_kind(ref_of(lexer), json.true_value(), 16)",
      "    if status != 0:",
      "        return status",
      "    status = take_kind(ref_of(lexer), json.right_brace(), 17)",
      "    if status != 0:",
      "        return status",
      "    status = take_kind(ref_of(lexer), json.eof(), 18)",
      "    if status != 0:",
      "        return status",
      "",
      "    return 0",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 0, result.exit_status
  end

  def test_host_runtime_reports_unterminated_jsonc_block_comments
    compiler = ENV.fetch("CC", "cc")
    skip "C compiler not available: #{compiler}" unless compiler_available?(compiler)

    source = [
      "module demo.std_jsonc_error",
      "",
      "import std.jsonc as jsonc",
      "import std.string as string",
      "",
      "def main() -> int:",
      "    let result = jsonc.normalize(\"{ /* broken\")",
      "    if result.is_ok:",
      "        var normalized = result.value",
      "        normalized.release()",
      "        return 1",
      "    return int<-result.error",
      "",
    ].join("\n")

    result = run_program(source, compiler:)

    assert_equal "", result.stdout
    assert_equal "", result.stderr
    assert_equal 2, result.exit_status
  end

  private

  def run_program(source, compiler:)
    Dir.mktmpdir("milk-tea-std-jsonc") do |dir|
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
