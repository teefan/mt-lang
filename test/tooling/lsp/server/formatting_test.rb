# frozen_string_literal: true

require_relative "helpers"

class FormattingTest < Minitest::Test
  include LSPServerTestHelpers

  def test_range_formatting_returns_text_edits
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_range_fmt_test.mt"
      source = "function add(a:int,b:int)->int:\n    return a+b\n"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/rangeFormatting", {
        "textDocument" => { "uri" => uri },
        "range" => {
          "start" => { "line" => 0, "character" => 0 },
          "end" => { "line" => 1, "character" => 14 }
        },
        "options" => { "tabSize" => 4, "insertSpaces" => true }
      })

      edits = response.fetch("result")
      assert_kind_of Array, edits
      assert_equal 1, edits.length
      assert_match(/function\s+add\(a:\s*int,\s*b:\s*int\)\s*->\s*int:/, edits[0]["newText"])
    end
  end

  def test_full_document_formatting_returns_text_edits
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_full_fmt_test.mt"
      source = "function add(a:int,b:int)->int:\n    return a+b\n"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/formatting", {
        "textDocument" => { "uri" => uri },
        "options" => { "tabSize" => 4, "insertSpaces" => true }
      })

      edits = response.fetch("result")
      assert_kind_of Array, edits
      assert_equal 1, edits.length
      edit = edits.first
      assert_equal 0, edit.dig("range", "start", "line")
      assert_equal 0, edit.dig("range", "start", "character")
      formatted = edit["newText"]
      refute_empty formatted
      assert_match(/function\s+add\(a:\s*int,\s*b:\s*int\)\s*->\s*int:/, formatted)
      assert_match(/return/, formatted)
    end
  end

  def test_full_document_formatting_returns_non_empty_for_valid_source
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_fmt_non_empty_test.mt"
      source = "const MAGIC = 42\nfunction main() -> int:\n    return MAGIC\n"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/formatting", {
        "textDocument" => { "uri" => uri },
        "options" => { "tabSize" => 4, "insertSpaces" => true }
      })

      edits = response.fetch("result")
      assert_kind_of Array, edits
      assert_equal 1, edits.length
      edit = edits.first
      assert_equal 0, edit.dig("range", "start", "line")
      assert_equal 0, edit.dig("range", "start", "character")
      assert edit.dig("range", "end", "line") >= 1
      refute_empty edit["newText"]
    end
  end

end
