# frozen_string_literal: true

require_relative "helpers"

class OnTypeFormattingTest < Minitest::Test
  include LSPServerTestHelpers

  def setup
    @counter = 0
  end

  def next_uri
    @counter += 1
    "file:///tmp/on_type_fmt_test_#{@counter}.mt"
  end

  def open_doc(client, uri, source)
    client.send_notification("textDocument/didOpen", {
      "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
    })
  end

  def request_on_type_format(client, uri, line, char, ch = "\n")
    client.send_request("textDocument/onTypeFormatting", {
      "textDocument" => { "uri" => uri },
      "position" => { "line" => line, "character" => char },
      "ch" => ch,
    })
  end

  # ── block introducers ──────────────────────────────────────────────

  def test_enter_after_function_indents
    with_shared_server do |client|
      uri = next_uri
      source = "function main() -> int:\n\n    return 0\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal "    ", edits.first["newText"]
      assert_equal 1, edits.first.dig("range", "start", "line")
      assert_equal 0, edits.first.dig("range", "start", "character")
    end
  end

  def test_enter_after_if_indents
    with_shared_server do |client|
      uri = next_uri
      source = "    if x == 1:\n\n        x = 2\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 8, edits.first["newText"]
    end
  end

  def test_enter_after_else_indents
    with_shared_server do |client|
      uri = next_uri
      source = "    else:\n\n        x = 3\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 8, edits.first["newText"]
    end
  end

  def test_enter_after_elif_indents
    with_shared_server do |client|
      uri = next_uri
      source = "    elif x == 2:\n\n        x = 3\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 8, edits.first["newText"]
    end
  end

  def test_enter_after_while_indents
    with_shared_server do |client|
      uri = next_uri
      source = "    while true:\n\n        pass\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 8, edits.first["newText"]
    end
  end

  def test_enter_after_for_indents
    with_shared_server do |client|
      uri = next_uri
      source = "    for i in 0..n:\n\n        pass\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 8, edits.first["newText"]
    end
  end

  def test_enter_after_match_indents
    with_shared_server do |client|
      uri = next_uri
      source = "    match val:\n\n        1: pass\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 8, edits.first["newText"]
    end
  end

  def test_enter_after_struct_indents
    with_shared_server do |client|
      uri = next_uri
      source = "struct Point:\n\n    x: int\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 4, edits.first["newText"]
    end
  end

  def test_enter_after_unsafe_indents
    with_shared_server do |client|
      uri = next_uri
      source = "    unsafe:\n\n        pass\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 8, edits.first["newText"]
    end
  end

  def test_enter_after_defer_indents
    with_shared_server do |client|
      uri = next_uri
      source = "    defer:\n\n        pass\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 8, edits.first["newText"]
    end
  end

  def test_enter_after_extending_indents
    with_shared_server do |client|
      uri = next_uri
      source = "extending Point:\n\n    function zero() -> int:\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 4, edits.first["newText"]
    end
  end

  # ── regular statements (same indent) ────────────────────────────────

  def test_enter_after_statement_keeps_indent
    with_shared_server do |client|
      uri = next_uri
      source = "    let x = 1\n\n    x = 3\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 4, edits.first["newText"]
    end
  end

  def test_enter_inside_block_keeps_indent
    with_shared_server do |client|
      uri = next_uri
      source = "        x = 2\n\n        y = 3\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 8, edits.first["newText"]
    end
  end

  # ── colon without block keyword ────────────────────────────────────

  def test_enter_after_parameter_colon_does_not_increase_indent
    with_shared_server do |client|
      uri = next_uri
      source = "    some_label:\n\n    x = 3\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)

      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 4, edits.first["newText"]
    end
  end

  def test_enter_after_typed_let_does_not_increase_indent
    with_shared_server do |client|
      uri = next_uri
      source = "    let x: int = 1\n\n    pass\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 4, edits.first["newText"]
    end
  end

  # ── same indent → no edit ─────────────────────────────────────────

  def test_enter_with_already_correct_indent_returns_empty
    with_shared_server do |client|
      uri = next_uri
      source = "    let x = 1\n    \n    x = 3\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      assert_equal [], response["result"]
    end
  end

  # ── walk back past empty lines ─────────────────────────────────────

  def test_enter_after_empty_line_looks_back_to_block_introducer
    with_shared_server do |client|
      uri = next_uri
      source = "    if x == 1:\n        x = 2\n\n\n        pass\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 3, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 8, edits.first["newText"]
    end
  end

  def test_enter_after_empty_line_looks_back_to_statement
    with_shared_server do |client|
      uri = next_uri
      source = "    let x = 1\n\n\n    x = 3\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 2, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 4, edits.first["newText"]
    end
  end

  def test_enter_with_only_blank_lines_above_returns_empty
    with_shared_server do |client|
      uri = next_uri
      source = "\n\n\n\n    code\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 3, 0)
      assert_equal [], response["result"]
    end
  end

  # ── non-Enter character ────────────────────────────────────────────

  def test_non_newline_character_returns_empty
    with_shared_server do |client|
      uri = next_uri
      source = "    let x = 1\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 0, 4, "}")
      assert_equal [], response["result"]
    end
  end

  # ── boundary positions ─────────────────────────────────────────────

  def test_position_zero_returns_empty
    with_shared_server do |client|
      uri = next_uri
      source = "function main() -> int:\n    return 0\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 0, 0)
      assert_equal [], response["result"]
    end
  end

  def test_position_beyond_length_returns_empty
    with_shared_server do |client|
      uri = next_uri
      source = "function main() -> int:\n    return 0\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 99, 0)
      assert_equal [], response["result"]
    end
  end

  # ── public keyword ─────────────────────────────────────────────────

  def test_enter_after_public_function_indents
    with_shared_server do |client|
      uri = next_uri
      source = "public function main() -> int:\n\n    return 0\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 4, edits.first["newText"]
    end
  end

  # ── Enter at start of dedented line (block exit) ────────────────────

  def test_enter_at_start_of_dedented_line_uses_below_indent
    with_shared_server do |client|
      uri = next_uri
      source = "        x = 2\n\n    x = 3\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 4, edits.first["newText"]
    end
  end

  def test_enter_at_start_of_dedented_line_multiple_levels
    with_shared_server do |client|
      uri = next_uri
      source = "            y = 9\n\n    x = 3\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 4, edits.first["newText"]
    end
  end

  def test_enter_between_block_body_and_else_keeps_body_indent
    with_shared_server do |client|
      uri = next_uri
      source = "        x = 2\n\n    else:\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 8, edits.first["newText"]
    end
  end

  def test_enter_between_block_body_and_elif_keeps_body_indent
    with_shared_server do |client|
      uri = next_uri
      source = "        x = 2\n\n    elif y == 1:\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 8, edits.first["newText"]
    end
  end

  def test_enter_at_start_of_same_indent_line_stays
    with_shared_server do |client|
      uri = next_uri
      source = "    let x = 1\n\n    let y = 2\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 4, edits.first["newText"]
    end
  end

  # ── unrealistic indent correction ──────────────────────────────────

  def test_indent_corrected_when_wrong
    with_shared_server do |client|
      uri = next_uri
      source = "    if x == 1:\n  \n        pass\n"
      open_doc(client, uri, source)

      response = request_on_type_format(client, uri, 1, 0)
      edits = response["result"]
      assert_equal 1, edits.length
      assert_equal " " * 8, edits.first["newText"]
      assert_equal 2, edits.first.dig("range", "end", "character")
    end
  end
end
