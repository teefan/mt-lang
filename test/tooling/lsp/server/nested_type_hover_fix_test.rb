# frozen_string_literal: true
require_relative "helpers"
require "tmpdir"

class NestedTypeHoverFixTest < Minitest::Test
  include LSPServerTestHelpers

  def test_hover_nested_type_in_qualified_type_annotation
    source = <<~MT
      struct Rectangle:
          x: float
          struct Edge:
              start: float
              end: float
          top_edge: Edge
      function demo() -> float:
          var e: Rectangle.Edge
          return e.top_edge.start
      function main() -> int:
          return 0
    MT

    Dir.mktmpdir("mt-hover-nested-type") do |dir|
      path = File.join(dir, "main.mt")
      File.write(path, source)

      with_lsp_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        # Hover on Rectangle
        rect_line = source.lines.index { |l| l.include?("var e: Rectangle.Edge") }
        rect_char = source.lines[rect_line].index("Rectangle")
        resp = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => rect_line, "character" => rect_char }
        })
        rect_val = resp.dig("result", "contents", "value")
        assert_includes rect_val, "Rectangle", "Rectangle hover should work"

        # Hover on Edge — should be "struct Edge", NOT "let Edge"
        edge_char = source.lines[rect_line].index("Edge")
        resp = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => rect_line, "character" => edge_char }
        })
        edge_val = resp.dig("result", "contents", "value")
        refute_includes edge_val, "let Edge", "Edge should NOT be shown as a variable (let)"
        assert_includes edge_val, "Edge", "Edge hover should work (not fall through to generic resolution)"
      end
    end
  end

  def test_definition_nested_type_in_qualified_annotation
    source = <<~MT
      struct Rectangle:
          x: float
          struct Edge:
              start: float
              end: float
          top_edge: Edge
      function demo() -> float:
          var e: Rectangle.Edge
          return e.top_edge.start
      function main() -> int:
          return 0
    MT

    Dir.mktmpdir("mt-def-nested-type") do |dir|
      path = File.join(dir, "main.mt")
      File.write(path, source)

      with_lsp_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        # Go-to-def on Edge in "Rectangle.Edge" should go to struct Edge declaration
        use_line = source.lines.index { |l| l.include?("var e: Rectangle.Edge") }
        use_char = source.lines[use_line].index("Edge")
        def_line = source.lines.index { |l| l.strip == "struct Edge:" }
        def_char = source.lines[def_line].index("Edge")

        resp = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => use_line, "character" => use_char }
        })
        result = resp.fetch("result")
        assert_equal def_line, result.dig("range", "start", "line")
        assert_equal def_char, result.dig("range", "start", "character")
      end
    end
  end
end
