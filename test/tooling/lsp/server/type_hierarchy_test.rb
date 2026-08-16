# frozen_string_literal: true

require_relative "helpers"

class TypeHierarchyTest < Minitest::Test
  include LSPServerTestHelpers

  def test_type_hierarchy_item_kinds_follow_symbol_kind_enum
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_type_hierarchy_kind_test.mt"
      source = <<~MT
        interface Shape:
            function area() -> float

        struct Circle implements Shape:
            radius: float
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/prepareTypeHierarchy", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 3, "character" => 8 }
      })

      item = response.fetch("result").first
      refute_nil item
      assert_equal 23, item["kind"], "struct must use SymbolKind.Struct (23)"
    end
  end
end
