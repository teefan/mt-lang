# frozen_string_literal: true

require_relative "helpers"

class SelectionRangeTest < Minitest::Test
  include LSPServerTestHelpers

  def test_selection_range_token_range_uses_cursor_line
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_selection_range_line_test.mt"
      source = "function main() -> int:\n    var value = 10\n    return value\n"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/selectionRange", {
        "textDocument" => { "uri" => uri },
        "positions" => [{ "line" => 1, "character" => 9 }]
      })

      ranges = response.fetch("result")
      innermost = ranges.first.fetch("range")
      # Cursor sits inside "value" on line 1; the innermost range must be on
      # that same line, not hardcoded to line 0.
      assert_equal 1, innermost.dig("start", "line")
      assert_equal 1, innermost.dig("end", "line")
      assert_operator innermost.dig("start", "character"), :<, innermost.dig("end", "character")
    end
  end
end
