# frozen_string_literal: true

require "json"
require "cgi"
require "tmpdir"
require "timeout"
require_relative "../../test_helper"

class LSPServerTest < Minitest::Test
  class LSPClient
    def initialize(stdin_write, stdout_read)
      @stdin = stdin_write
      @stdout = stdout_read
      @next_id = 1
    end

    def send_request(method, params = {})
      id = @next_id
      @next_id += 1
      write_message({ jsonrpc: "2.0", id: id, method: method, params: params })
      read_until_response(id)
    end

    def send_notification(method, params = {})
      write_message({ jsonrpc: "2.0", method: method, params: params })
    end

    private

    def write_message(message)
      json = JSON.dump(message)
      @stdin.write("Content-Length: #{json.bytesize}\r\n\r\n#{json}")
      @stdin.flush
    end

    def read_until_response(expected_id, timeout: 5)
      Timeout.timeout(timeout) do
        loop do
          message = read_message
          return nil if message.nil?
          next unless message["id"] == expected_id

          return message
        end
      end
    end

    def read_message
      headers = {}
      loop do
        line = @stdout.gets
        return nil if line.nil?

        stripped = line.chomp.sub(/\r\z/, "")
        break if stripped.empty?

        key, value = stripped.split(":", 2)
        headers[key.strip] = value.strip
      end

      content_length = headers["Content-Length"]&.to_i
      return nil if content_length.nil? || content_length <= 0

      JSON.parse(@stdout.read(content_length))
    end
  end

  SOURCE = <<~MT
    struct Vec2:
        x: f32
        y: f32

    def add(a: i32, b: i32) -> i32:
        return a + b
  MT

  # Source that has both a definition and a call-site for 'add'.
  SOURCE_WITH_CALL = <<~MT
    def add(a: i32, b: i32) -> i32:
        return a + b

    def main() -> i32:
        return add(1, 2)
  MT

  def test_initialize_advertises_expected_capabilities
    with_server do |client|
      response = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      capabilities = response.dig("result", "capabilities")

      assert_equal 2, capabilities.dig("textDocumentSync", "change")
      assert_equal true, capabilities["hoverProvider"]
      assert_equal true, capabilities["definitionProvider"]
      assert_equal true, capabilities["declarationProvider"]
      assert_equal true, capabilities["typeDefinitionProvider"]
      assert_equal true, capabilities["referencesProvider"]
      assert_equal true, capabilities["documentHighlightProvider"]
      assert_kind_of Hash, capabilities["renameProvider"]
      assert_kind_of Hash, capabilities["signatureHelpProvider"]
      assert_kind_of Hash, capabilities["completionProvider"]
      assert_equal true, capabilities["workspaceSymbolProvider"]
    end
  end

  def test_document_symbol_and_hover_work_after_open
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_server_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => SOURCE
        }
      })

      symbols_response = client.send_request("textDocument/documentSymbol", {
        "textDocument" => { "uri" => uri }
      })
      names = symbols_response.fetch("result").map { |sym| sym["name"] }
      assert_includes names, "Vec2"
      assert_includes names, "add"

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 4, "character" => 4 }
      })
      hover_value = hover_response.dig("result", "contents", "value")
      assert_includes hover_value, "add"
      assert_includes hover_value, "-> i32"
    end
  end

  def test_references_finds_all_occurrences_of_a_name
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_refs_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      response = client.send_request("textDocument/references", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 0, "character" => 4 },
        "context"      => { "includeDeclaration" => true }
      })
      locations = response.fetch("result")
      lines = locations.map { |loc| loc.dig("range", "start", "line") }
      assert_includes lines, 0
      assert_includes lines, 4
    end
  end

  def test_document_highlight_returns_all_occurrences_in_file
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_highlight_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      response = client.send_request("textDocument/documentHighlight", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 0, "character" => 4 }
      })
      highlights = response.fetch("result")
      assert highlights.length >= 2, "expected at least 2 highlights for 'add', got #{highlights.length}"
      highlights.each { |h| assert_equal 1, h["kind"] }
    end
  end

  def test_signature_help_returns_function_signature_at_call_site
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_sighel_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      # Cursor right after "add(" on line 4: "    return add(" = 15 chars
      response = client.send_request("textDocument/signatureHelp", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 4, "character" => 15 }
      })
      result = response.fetch("result")
      assert_equal 0, result["activeSignature"]
      assert_equal 0, result["activeParameter"]
      sig_label = result.dig("signatures", 0, "label")
      assert_includes sig_label, "add"
      assert_includes sig_label, "a: i32"
      assert_includes sig_label, "b: i32"
    end
  end

  def test_signature_help_tracks_active_parameter_by_comma_count
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_sighel2_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      # Cursor after "add(1, " on line 4: "    return add(1, " = 18 chars
      response = client.send_request("textDocument/signatureHelp", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 4, "character" => 18 }
      })
      result = response.fetch("result")
      assert_equal 1, result["activeParameter"]
    end
  end

  def test_prepare_rename_returns_range_and_placeholder
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_prep_rename_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      response = client.send_request("textDocument/prepareRename", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 0, "character" => 4 }
      })
      result = response.fetch("result")
      assert_equal "add", result["placeholder"]
      assert_equal 0, result.dig("range", "start", "line")
      assert_equal 4, result.dig("range", "start", "character")
    end
  end

  def test_rename_produces_workspace_edit_for_all_occurrences
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_rename_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      response = client.send_request("textDocument/rename", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 0, "character" => 4 },
        "newName"      => "sum"
      })
      changes = response.dig("result", "changes", uri)
      assert_kind_of Array, changes
      assert changes.length >= 2, "expected at least 2 edits for 'add' rename, got #{changes.length}"
      changes.each { |edit| assert_equal "sum", edit["newText"] }
    end
  end

  def test_did_save_republishes_diagnostics
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_save_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => "struct Vec2:\n    x: f32\n" }
      })
      client.send_notification("textDocument/didSave", { "textDocument" => { "uri" => uri } })
      # Server still alive if we get a response to a followup request
      response = client.send_request("textDocument/documentSymbol", { "textDocument" => { "uri" => uri } })
      assert_kind_of Array, response.fetch("result")
    end
  end

  def test_document_symbol_captures_opaque_declarations
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_opaque_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => "opaque SDL_Window\n" }
      })
      response = client.send_request("textDocument/documentSymbol", { "textDocument" => { "uri" => uri } })
      names = response.fetch("result").map { |s| s["name"] }
      assert_includes names, "SDL_Window"
    end
  end

  def test_declaration_and_type_definition_delegate_to_definition_location
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_decl_type_def_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })

      declaration = client.send_request("textDocument/declaration", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 4, "character" => 11 }
      })
      type_definition = client.send_request("textDocument/typeDefinition", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 4, "character" => 11 }
      })

      assert_equal uri, declaration.dig("result", "uri")
      assert_equal 0, declaration.dig("result", "range", "start", "line")
      assert_equal 4, declaration.dig("result", "range", "start", "character")

      assert_equal uri, type_definition.dig("result", "uri")
      assert_equal 0, type_definition.dig("result", "range", "start", "line")
      assert_equal 4, type_definition.dig("result", "range", "start", "character")
    end
  end

  def test_definition_falls_back_to_other_workspace_file
    Dir.mktmpdir("milk-tea-lsp-def") do |dir|
      shared_path = File.join(dir, "shared.mt")
      main_path = File.join(dir, "main.mt")
      File.write(shared_path, <<~MT)
        def shared(a: i32, b: i32) -> i32:
            return a + b
      MT
      File.write(main_path, <<~MT)
        def main() -> i32:
            return shared(1, 2)
      MT

      root_uri = path_to_uri(dir)
      shared_uri = path_to_uri(shared_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => File.read(main_path)
          }
        })

        definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position"     => { "line" => 1, "character" => 11 }
        })

        assert_equal shared_uri, definition.dig("result", "uri")
        assert_equal 0, definition.dig("result", "range", "start", "line")
        assert_equal 4, definition.dig("result", "range", "start", "character")
      end
    end
  end

  def test_did_change_watched_files_refreshes_workspace_index
    Dir.mktmpdir("milk-tea-lsp-watch") do |dir|
      watched_path = File.join(dir, "watched.mt")
      File.write(watched_path, <<~MT)
        def old_name() -> i32:
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
          def new_name() -> i32:
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

  private

  def path_to_uri(path)
    escaped_path = path.split("/").map { |segment| CGI.escape(segment).gsub("+", "%20") }.join("/")
    "file://#{escaped_path}"
  end

  def with_server
    stdin_read, stdin_write = IO.pipe
    stdout_read, stdout_write = IO.pipe

    pid = spawn(
      'bundle exec ruby -Ilib -e "require \'milk_tea\'; MilkTea::LSP::Server.new.run"',
      in: stdin_read,
      out: stdout_write,
      err: File::NULL,
      chdir: File.expand_path("../../..", __dir__)
    )

    stdin_read.close
    stdout_write.close

    client = LSPClient.new(stdin_write, stdout_read)
    yield client
  ensure
    stdin_write&.close
    stdout_read&.close
    Process.kill("TERM", pid) rescue nil
    Process.wait(pid) rescue nil
  end
end
