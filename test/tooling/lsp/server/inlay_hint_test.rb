# frozen_string_literal: true

require_relative "helpers"

class InlayHintTest < Minitest::Test
  include LSPServerTestHelpers

  SOURCE_WITH_FUNCTION_CALL = <<~MT
    struct Point:
        x: int
        y: int

    function move(p: Point, dx: int, dy: int) -> Point:
        return Point(x = p.x + dx, y = p.y + dy)

    function main() -> int:
        var origin = Point(x = 0, y = 0)
        var moved = move(origin, 5, 10)
        return 0
  MT

  SOURCE_WITH_METHOD_CALL = <<~MT
    struct Player:
        hp: int

    extending Player:
        editable function take_damage(amount: int, source: int) -> void:
            this.hp = this.hp - amount

    function main() -> int:
        var p = Player(hp = 100)
        p.take_damage(25, 1)
        return 0
  MT

  def test_parameter_name_hints_for_function_call
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_ih_func_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_FUNCTION_CALL }
      })

      response = client.send_request("textDocument/inlayHint", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 0, "character" => 0 }, "end" => { "line" => 20, "character" => 0 } }
      })
      result = response.fetch("result")
      labels = result.map { |hint| hint["label"] }

      # move(origin, 5, 10) with params (p: Point, dx: int, dy: int)
      # "origin" is self-describing (named like param) so no hint for p
      assert_includes labels, "dx: "
      assert_includes labels, "dy: "
    end
  end

  def test_parameter_name_hints_for_method_call
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_ih_method_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_METHOD_CALL }
      })

      response = client.send_request("textDocument/inlayHint", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 0, "character" => 0 }, "end" => { "line" => 20, "character" => 0 } }
      })
      result = response.fetch("result")
      labels = result.map { |hint| hint["label"] }

      # take_damage(amount: int, source: int) called as take_damage(25, 1)
      assert_includes labels, "amount: "
      assert_includes labels, "source: "
    end
  end

  def test_parameter_name_hints_omit_named_arguments
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_ih_named_test.mt"
      source = <<~MT
        struct Point:
            x: int
            y: int

        function new_point(x_axis: int, y_axis: int) -> Point:
            return Point(x = x_axis, y = y_axis)

        function main() -> int:
            var pt = new_point(x_axis = 10, y_axis = 20)
            return 0
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/inlayHint", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 0, "character" => 0 }, "end" => { "line" => 20, "character" => 0 } }
      })
      result = response.fetch("result")

      # Already-named args should not get additional hints
      labels = result.map { |hint| hint["label"] }
      refute labels.any? { |l| l.include?("x_axis") || l.include?("y_axis") },
             "Already-named arguments should not have hints"
    end
  end
end
