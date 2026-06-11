# frozen_string_literal: true

require_relative "helpers"

class FoldingRangeTest < Minitest::Test
  include LSPServerTestHelpers
  def test_folds_function_body
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_folding_test.mt"
      source = <<~MT
        function add(a: int, b: int) -> int:
            return a + b

        function main() -> int:
            return add(1, 2)
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/foldingRange", {
        "textDocument" => { "uri" => uri }
      })
      folds = response.fetch("result")
      assert_equal 2, folds.length
      assert_equal 0, folds[0]["startLine"]
      assert_equal 1, folds[0]["endLine"]
      assert_equal 3, folds[1]["startLine"]
      assert_equal 4, folds[1]["endLine"]
    end
  end

  def test_folds_if_else_blocks
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_folding_if_test.mt"
      source = <<~MT
        function test(x: int) -> int:
            if x > 0:
                return 1
            elif x == 0:
                return 0
            else:
                return -1
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/foldingRange", {
        "textDocument" => { "uri" => uri }
      })
      folds = response.fetch("result")
      start_lines = folds.map { |f| f["startLine"] }.sort
      assert_equal [0, 1, 3, 5], start_lines, "expected function + if/elif/else bodies"
      assert folds.all? { |f| f["kind"].nil? || f["kind"] == "region" }
    end
  end

  def test_folds_while_loop
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_folding_while_test.mt"
      source = <<~MT
        function main() -> int:
            while true:
                do_work()
            return 0
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/foldingRange", {
        "textDocument" => { "uri" => uri }
      })
      folds = response.fetch("result")
      labels = folds.map { |f| [f["startLine"], f["endLine"]] }.sort
      assert_equal [[0, 3], [1, 2]], labels
    end
  end

  def test_folds_match_arms
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_folding_match_test.mt"
      source = <<~MT
        function test(v: int) -> int:
            match v:
                when 0:
                    return 10
                when 1:
                    return 20
            return 0
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/foldingRange", {
        "textDocument" => { "uri" => uri }
      })
      folds = response.fetch("result")
      start_lines = folds.map { |f| f["startLine"] }.sort
      assert_equal [0, 1, 2, 4], start_lines, "expected function + match + two when arms"
    end
  end

  def test_folds_struct_enum
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_folding_struct_test.mt"
      source = <<~MT
        struct Vec2:
            x: int
            y: int

        enum Color:
            Red = 0
            Green = 1
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/foldingRange", {
        "textDocument" => { "uri" => uri }
      })
      folds = response.fetch("result")
      start_lines = folds.map { |f| f["startLine"] }.sort
      assert_equal [0, 4], start_lines, "expected struct + enum folds"
    end
  end

  def test_folds_import_group
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_folding_import_test.mt"
      source = <<~MT
        import std.raylib as rl
        import std.math as math

        function main() -> int:
            return 0
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/foldingRange", {
        "textDocument" => { "uri" => uri }
      })
      folds = response.fetch("result")
      import_fold = folds.find { |f| f["kind"] == "imports" }
      refute_nil import_fold, "expected an import fold"
      assert_equal 0, import_fold["startLine"]
      assert_equal 1, import_fold["endLine"]
    end
  end

  def test_folds_multiline_comment
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_folding_comment_test.mt"
      source = <<~MT
        #> this is a
           multi-line
           comment <#
        function f() -> int:
            return 1
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/foldingRange", {
        "textDocument" => { "uri" => uri }
      })
      folds = response.fetch("result")
      comment_fold = folds.find { |f| f["kind"] == "comment" }
      refute_nil comment_fold, "expected a comment fold"
      assert_equal 0, comment_fold["startLine"]
      assert_equal 2, comment_fold["endLine"]
    end
  end

  def test_no_folds_on_empty_file
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_folding_empty_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => "" }
      })

      response = client.send_request("textDocument/foldingRange", {
        "textDocument" => { "uri" => uri }
      })
      assert_equal [], response.fetch("result")
    end
  end
end
