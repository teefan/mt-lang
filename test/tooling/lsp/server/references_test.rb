# frozen_string_literal: true

require_relative "helpers"

class ReferencesTest < Minitest::Test
  include LSPServerTestHelpers

  def test_references_finds_all_occurrences_of_a_name
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      response = client.send_request("textDocument/references", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 0, "character" => 9 },
        "context"      => { "includeDeclaration" => true }
      })
      locations = response.fetch("result")
      lines = locations.map { |loc| loc.dig("range", "start", "line") }
      assert_includes lines, 0
      assert_includes lines, 4
    end
  end

  def test_references_on_imported_type_static_method_are_receiver_scoped
    Dir.mktmpdir("milk-tea-lsp-refs-imported-type") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      foo_source = <<~MT
        public struct Point:
            x: int
            y: int

        extending Point:
            public static function zero() -> int:
                return 0

        public function call_zero() -> int:
            return Point.zero()
      MT
      other_source = <<~MT
        public function zero() -> int:
            return 0

        public function call_zero() -> int:
            return zero()
      MT
      main_source = <<~MT
        import std.foo as foo

        public function main() -> int:
            return foo.Point.zero()
      MT

      foo_path = File.join(std_dir, "foo.mt")
      other_path = File.join(dir, "other.mt")
      main_path = File.join(dir, "main.mt")
      File.write(foo_path, foo_source)
      File.write(other_path, other_source)
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      foo_uri = path_to_uri(foo_path)
      other_uri = path_to_uri(other_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        call_line = main_source.lines.index { |line| line.include?("foo.Point.zero") }
        call_char = main_source.lines[call_line].index("zero") + 1

        response = client.send_request("textDocument/references", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char },
          "context" => { "includeDeclaration" => true }
        })

        locations = response.fetch("result")
        starts = locations.map { |loc| [loc["uri"], loc.dig("range", "start", "line")] }
        foo_definition_line = foo_source.lines.index { |line| line.include?("static function zero") }
        foo_call_line = foo_source.lines.index { |line| line.include?("Point.zero") }

        assert_includes starts, [foo_uri, foo_definition_line]
        assert_includes starts, [foo_uri, foo_call_line]
        assert_includes starts, [main_uri, call_line]
        refute_includes starts, [other_uri, other_source.lines.index { |line| line.include?("function zero") }]
        refute_includes starts, [other_uri, other_source.lines.index { |line| line.include?("return zero()") }]
      end
    end
  end

  def test_references_local_variable_are_scoped_under_shadowing
    source = <<~MT
      function main() -> int:
          let value = 1
          let a = value
          if true:
              let value = 2
              let b = value
          return value
    MT

    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_references_shadowed_local.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/references", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 5, "character" => 17 },
        "context"      => { "includeDeclaration" => true }
      })

      refs = response.fetch("result")
      assert_equal 2, refs.length
      starts = refs.map { |entry| [entry.dig("range", "start", "line"), entry.dig("range", "start", "character")] }
      assert_includes starts, [4, 12]
      assert_includes starts, [5, 16]
    end
  end

  def test_document_highlight_returns_all_occurrences_in_file
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_highlight_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      response = client.send_request("textDocument/documentHighlight", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 0, "character" => 9 }
      })
      highlights = response.fetch("result")
      assert highlights.length >= 2, "expected at least 2 highlights for 'add', got #{highlights.length}"
      highlights.each { |h| assert_equal 1, h["kind"] }
    end
  end

  def test_document_highlight_local_variable_is_scoped_under_shadowing
    source = <<~MT
      function main() -> int:
          let value = 1
          let a = value
          if true:
              let value = 2
              let b = value
          return value
    MT

    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_highlight_shadowed_local.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/documentHighlight", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 5, "character" => 17 }
      })

      highlights = response.fetch("result")
      assert_equal 2, highlights.length
      starts = highlights.map { |entry| [entry.dig("range", "start", "line"), entry.dig("range", "start", "character")] }
      assert_includes starts, [4, 12]
      assert_includes starts, [5, 16]
    end
  end

  def test_did_change_watched_files_refreshes_workspace_index
    Dir.mktmpdir("milk-tea-lsp-watch") do |dir|
      watched_path = File.join(dir, "watched.mt")
      File.write(watched_path, <<~MT)
        function old_name() -> int:
            return 0
      MT

      root_uri = path_to_uri(dir)
      watched_uri = path_to_uri(watched_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})

        old_symbols = client.send_request("workspace/symbol", { "query" => "old_name" })
        old_names = old_symbols.fetch("result").map { |s| s["name"] }
        assert_includes old_names, "old_name"

        File.write(watched_path, <<~MT)
          function new_name() -> int:
              return 0
        MT

        client.send_notification("workspace/didChangeWatchedFiles", {
          "changes" => [{ "uri" => watched_uri, "type" => 2 }]
        })

        new_symbols = client.send_request("workspace/symbol", { "query" => "new_name" })
        new_names = new_symbols.fetch("result").map { |s| s["name"] }
        assert_includes new_names, "new_name"
      end
    end
  end

end
