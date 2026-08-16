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

  def test_document_symbol_includes_resolved_local_types
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_doc_symbol_type_test.mt"
      source = <<~MT
        struct Pair:
            x: int
            y: int

        function main() -> int:
            var count = 0
            let p = Pair(x = 1, y = 2)
            let ptr: ptr[int]? = null
            let val = ptr else:
                return 0
            return count + p.x
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/documentSymbol", {
        "textDocument" => { "uri" => uri }
      })

      symbols = response.fetch("result")
      main = symbols.find { |s| s["name"] == "main" }
      refute_nil main
      assert_equal "-> int", main["detail"]

      locals = main.fetch("children").to_h { |s| [s["name"], s["detail"]] }
      assert_equal "int", locals["count"]
      assert_equal "Pair", locals["p"]
      assert_equal "ptr[int]?", locals["ptr"]
      assert_equal "ptr[int]", locals["val"]
    end
  end

  def test_short_type_detail_strips_module_qualifiers
    enricher = Object.new
    enricher.extend(MilkTea::LSP::Server::ServerFormatting)

    deque_def = MilkTea::Types::GenericStructDefinition.new("Deque", ["T"], module_name: "std.deque")
    deque_int = deque_def.instantiate([MilkTea::Types::Primitive.new("int")])
    assert_equal "Deque[int]", enricher.send(:short_type_detail, deque_int)

    nested = MilkTea::Types::GenericInstance.new("array", [deque_int, MilkTea::Types::LiteralTypeArg.new(4)])
    assert_equal "array[Deque[int], 4]", enricher.send(:short_type_detail, nested)

    nullable = MilkTea::Types::Nullable.new(deque_int)
    assert_equal "Deque[int]?", enricher.send(:short_type_detail, nullable)

    imported = MilkTea::Types::Struct.new("Vector2", module_name: "std.raylib")
    assert_equal "Vector2", enricher.send(:short_type_detail, imported)
  end

  def test_document_symbol_shows_types_for_declarations
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_doc_symbol_decls_test.mt"
      source = <<~MT
        type Handler = fn(value: int) -> bool

        struct Filter:
            check: fn(value: int) -> bool

        struct Pair:
            x: int
            y: int

        var counter: int = 0

        function noop():
            pass

        external function c_thing(value: int) -> int

        function main() -> int:
            let p = Pair(x = 1, y = 2)
            let Pair(a, b) = p
            return a + b
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/documentSymbol", {
        "textDocument" => { "uri" => uri }
      })

      symbols = response.fetch("result").to_h { |s| [s["name"], s] }

      assert_equal "= fn(int) -> bool", symbols.fetch("Handler")["detail"]
      assert_equal "int", symbols.fetch("counter")["detail"]
      assert_equal "-> void", symbols.fetch("noop")["detail"]
      assert_equal "-> int", symbols.fetch("c_thing")["detail"]

      filter = symbols.fetch("Filter")
      assert_equal "fn(int) -> bool", filter.fetch("children").find { |c| c["name"] == "check" }["detail"]

      main = symbols.fetch("main")
      assert_equal "Pair", main.fetch("children").find { |c| c["name"] == "p" }["detail"]
      refute main.fetch("children").any? { |c| c["name"] == "Pair" }
    end
  end

  def test_document_symbol_shows_generic_variant_and_enum_details
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_doc_symbol_generic_test.mt"
      source = <<~MT
        enum State: ubyte
            idle = 0
            running = 1

        struct Pair[A, B]:
            first: A
            second: B

        variant TokenKind:
            ident(name: str)
            eof

        function main() -> int:
            return 0
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/documentSymbol", {
        "textDocument" => { "uri" => uri }
      })

      symbols = response.fetch("result").to_h { |s| [s["name"], s] }

      assert_equal ": ubyte", symbols.fetch("State")["detail"]
      assert_equal "[A, B]", symbols.fetch("Pair")["detail"]

      pair_children = symbols.fetch("Pair").fetch("children").to_h { |c| [c["name"], c["detail"]] }
      assert_equal "A", pair_children["first"]
      assert_equal "B", pair_children["second"]

      token_kind = symbols.fetch("TokenKind")
      refute token_kind["detail"]
      arm_details = token_kind.fetch("children").to_h { |c| [c["name"], c["detail"]] }
      assert_equal "(name: str)", arm_details["ident"]
      refute arm_details["eof"]
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
