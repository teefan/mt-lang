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

  # Source with a struct + methods block so method completion/hover can be tested.
  SOURCE_WITH_METHODS = <<~MT
    struct Point:
        x: i32
        y: i32

    methods Point:
        def zero() -> i32:
            return 0

    def get_val() -> i32:
        return 1
  MT

  SOURCE_WITH_LOCAL_VALUE_COMPLETION = <<~MT
    struct Point:
        x: i32
        y: i32

    methods Point:
        def length() -> i32:
            return this.x + this.y

    def main() -> i32:
        let p = Point(x = 1, y = 2)
        return p.x
  MT

  SOURCE_WITH_SHADOWED_VALUE_COMPLETION = <<~MT
    struct Point:
        x: i32

    struct Size:
        w: i32

    def main() -> i32:
        let v = Point(x = 1)
        if true:
            let v = Size(w = 2)
            let _inner = v.w
        return v.x
  MT

  SOURCE_WITH_NULLABLE_FLOW_COMPLETION = <<~MT
    struct Point:
        x: i32

    def main() -> i32:
        var p: Point? = null
        if p != null:
            return p.x
        return 0
  MT

  SOURCE_WITH_REF_RECEIVER_COMPLETION = <<~MT
    struct Point:
        x: i32
        y: i32

    def main() -> i32:
        var p = Point(x = 1, y = 2)
        let rp = ref_of(p)
        return rp.x
  MT

  SOURCE_WITH_POINTER_RECEIVER_COMPLETION = <<~MT
    struct Point:
        x: i32
        y: i32

    def main() -> i32:
        var p = Point(x = 1, y = 2)
        let pp = ptr_of(ref_of(p))
        unsafe:
            return pp.x
  MT

  SOURCE_WITH_TOP_LEVEL_VALUE_RECEIVER_COMPLETION = <<~MT
    struct Point:
        x: i32
        y: i32

    methods Point:
        def area() -> i32:
            return this.x * this.y

    var origin: Point = Point(x = 3, y = 4)

    def main() -> i32:
        return origin.x
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
      assert_equal true, capabilities["documentRangeFormattingProvider"]
      assert_kind_of Hash, capabilities["codeActionProvider"]
      assert_equal true, capabilities["inlayHintProvider"]
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

  def test_range_formatting_returns_text_edits
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_range_fmt_test.mt"
      source = "def add(a:i32,b:i32)->i32:\n    return a+b\n"
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
      assert_match(/def\s+add\(a:\s*i32,\s*b:\s*i32\)\s*->\s*i32:/, edits[0]["newText"])
    end
  end

  def test_code_action_returns_source_fixall_action
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_code_action_test.mt"
      source = "def add(a:i32,b:i32)->i32:\n    return a+b\n"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => {
          "start" => { "line" => 0, "character" => 0 },
          "end" => { "line" => 1, "character" => 14 }
        },
        "context" => { "diagnostics" => [], "only" => ["source.fixAll"] }
      })

      actions = response.fetch("result")
      assert_kind_of Array, actions
      fixall = actions.find { |a| a["kind"] == "source.fixAll" }
      assert fixall, "expected a source.fixAll action"
      assert_equal "Apply all auto-fixes", fixall["title"]
      assert_kind_of Hash, fixall.dig("edit", "changes")
      assert_kind_of Array, fixall.dig("edit", "changes", uri)
    end
  end

  def test_code_action_skips_source_fixall_for_workspace_std_files
    Dir.mktmpdir("milk-tea-lsp-code-action-std") do |dir|
      std_dir = File.join(dir, "std", "c")
      Dir.mkdir(File.join(dir, "std"))
      Dir.mkdir(std_dir)

      file_path = File.join(std_dir, "sdl3.mt")
      source = "def add(a:i32,b:i32)->i32:\n    return a+b\n"
      File.write(file_path, source)

      root_uri = path_to_uri(dir)
      uri = path_to_uri(file_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/codeAction", {
          "textDocument" => { "uri" => uri },
          "range" => {
            "start" => { "line" => 0, "character" => 0 },
            "end" => { "line" => 1, "character" => 14 }
          },
          "context" => { "diagnostics" => [] }
        })

        actions = response.fetch("result")
        refute actions.any? { |a| a["kind"] == "source.fixAll" }
      end
    end
  end

  def test_inlay_hint_returns_parameter_name_hints_for_call_arguments
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_inlay_hint_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })

      response = client.send_request("textDocument/inlayHint", {
        "textDocument" => { "uri" => uri },
        "range" => {
          "start" => { "line" => 4, "character" => 0 },
          "end" => { "line" => 4, "character" => 30 }
        }
      })

      hints = response.fetch("result")
      labels = hints.map { |h| h["label"] }
      assert_includes labels, "a: "
      assert_includes labels, "b: "

      positions = hints.map { |h| [h.dig("position", "line"), h.dig("position", "character")] }
      assert_includes positions, [4, 15]
      assert_includes positions, [4, 18]
    end
  end

  def test_inlay_hint_respects_requested_range
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_inlay_hint_range_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })

      response = client.send_request("textDocument/inlayHint", {
        "textDocument" => { "uri" => uri },
        "range" => {
          "start" => { "line" => 4, "character" => 0 },
          "end" => { "line" => 4, "character" => 16 }
        }
      })

      hints = response.fetch("result")
      labels = hints.map { |h| h["label"] }
      assert_includes labels, "a: "
      refute_includes labels, "b: "
    end
  end

  def test_document_diagnostic_returns_full_report
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_doc_diag_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => "def add(a: i32, b: i32) -> i32:\n    return a + b\n"
        }
      })

      response = client.send_request("textDocument/diagnostic", {
        "textDocument" => { "uri" => uri }
      })

      result = response.fetch("result")
      assert_equal "full", result["kind"]
      assert_kind_of Array, result["items"]
      assert_equal [], result["items"]
    end
  end

  def test_document_diagnostic_reports_syntax_errors
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_doc_diag_err_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => "def bad(\n"
        }
      })

      response = client.send_request("textDocument/diagnostic", {
        "textDocument" => { "uri" => uri }
      })

      result = response.fetch("result")
      assert_equal "full", result["kind"]
      assert result["items"].length >= 1
      assert_match(/expected|unterminated|unclosed|error/i, result["items"][0]["message"])
    end
  end

  def test_document_diagnostic_returns_unchanged_when_previous_result_matches
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_doc_diag_unchanged_test.mt"
      source = "def add(a: i32, b: i32) -> i32:\n    return a + b\n"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source
        }
      })

      first = client.send_request("textDocument/diagnostic", {
        "textDocument" => { "uri" => uri }
      })
      first_result = first.fetch("result")
      assert_equal "full", first_result["kind"]
      refute_nil first_result["resultId"]

      second = client.send_request("textDocument/diagnostic", {
        "textDocument" => { "uri" => uri },
        "previousResultId" => first_result["resultId"]
      })
      second_result = second.fetch("result")
      assert_equal "unchanged", second_result["kind"]
      assert_equal first_result["resultId"], second_result["resultId"]
    end
  end

  def test_document_diagnostic_returns_full_after_content_changes
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_doc_diag_change_test.mt"
      source = "def add(a: i32, b: i32) -> i32:\n    return a + b\n"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source
        }
      })

      first = client.send_request("textDocument/diagnostic", {
        "textDocument" => { "uri" => uri }
      })
      first_result = first.fetch("result")
      assert_equal "full", first_result["kind"]

      changed = "def add(a: i32, b: i32) -> i32:\n    return a - b\n"
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => changed }]
      })

      second = client.send_request("textDocument/diagnostic", {
        "textDocument" => { "uri" => uri },
        "previousResultId" => first_result["resultId"]
      })
      second_result = second.fetch("result")
      assert_equal "full", second_result["kind"]
      refute_equal first_result["resultId"], second_result["resultId"]
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

  def test_definition_on_imported_module_member_jumps_to_member_declaration
    Dir.mktmpdir("milk-tea-lsp-def-member") do |dir|
      lib_path = File.join(dir, "demo", "lib.mt")
      main_path = File.join(dir, "main.mt")
      Dir.mkdir(File.join(dir, "demo"))

      lib_source = <<~MT
        module demo.lib

        def greet() -> i32:
            return 1
      MT
      main_source = <<~MT
        module demo.main

        import demo.lib as lib

        def main() -> i32:
            return lib.greet()
      MT

      File.write(lib_path, lib_source)
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      lib_uri = path_to_uri(lib_path)
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

        call_line = main_source.lines.index { |line| line.include?("lib.greet") }
        call_char = main_source.lines[call_line].index("greet") + 1

        definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        assert_equal lib_uri, definition.dig("result", "uri")
        assert_equal 2, definition.dig("result", "range", "start", "line")
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

  def test_completion_returns_function_names
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_completion_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 4, "character" => 11 }
      })
      result = response.fetch("result")
      labels = result["items"].map { |i| i["label"] }
      assert_includes labels, "add"
      assert_includes labels, "main"
      result["items"].each { |item| assert_equal 3, item["kind"] }
    end
  end

  def test_completion_returns_method_names_after_dot
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_method_completion_test.mt"
      # Open valid source so analysis succeeds and is cached as last-good.
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_METHODS }
      })
      # Simulate user editing to a mid-state with "p." on the last line (breaks sema,
      # but last-good analysis is retained so method completions still work).
      partial_source = SOURCE_WITH_METHODS.sub("    return 1\n", "    return p.\n")
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => partial_source }]
      })
      # Cursor is right after 'p.' on the last non-empty line.
      dot_line = partial_source.lines.count - 1  # "    return p." is the last line
      dot_char = partial_source.lines[dot_line].chomp.length

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => dot_line, "character" => dot_char }
      })
      result = response.fetch("result")
      labels = result["items"].map { |i| i["label"] }
      assert_includes labels, "zero"
      result["items"].each { |item| assert_equal 2, item["kind"] }  # kind 2 = Method
    end
  end

  def test_completion_returns_fields_and_methods_for_local_value_receiver
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_local_value_completion_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_LOCAL_VALUE_COMPLETION }
      })

      partial_source = SOURCE_WITH_LOCAL_VALUE_COMPLETION.sub("return p.x", "return p.")
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => partial_source }]
      })

      dot_line = partial_source.lines.index { |line| line.include?("return p.") }
      dot_char = partial_source.lines[dot_line].chomp.length

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => dot_line, "character" => dot_char }
      })

      items = response.fetch("result").fetch("items")
      labels = items.map { |i| i["label"] }
      kinds_by_label = items.to_h { |i| [i["label"], i["kind"]] }

      assert_includes labels, "x"
      assert_includes labels, "y"
      assert_includes labels, "length"
      assert_equal 10, kinds_by_label["x"]
      assert_equal 2, kinds_by_label["length"]
    end
  end

  def test_completion_uses_lexical_scope_for_shadowed_value_receiver
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_shadow_value_completion_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_SHADOWED_VALUE_COMPLETION }
      })

      partial_source = SOURCE_WITH_SHADOWED_VALUE_COMPLETION.sub("return v.x", "return v.")
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => partial_source }]
      })

      dot_line = partial_source.lines.index { |line| line.include?("return v.") }
      dot_char = partial_source.lines[dot_line].chomp.length

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => dot_line, "character" => dot_char }
      })

      labels = response.fetch("result").fetch("items").map { |i| i["label"] }
      assert_includes labels, "x"
      refute_includes labels, "w"
    end
  end

  def test_completion_uses_flow_refined_type_for_nullable_receiver
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_nullable_flow_completion_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_NULLABLE_FLOW_COMPLETION }
      })

      partial_source = SOURCE_WITH_NULLABLE_FLOW_COMPLETION.sub("return p.x", "return p.")
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => partial_source }]
      })

      dot_line = partial_source.lines.index { |line| line.include?("return p.") }
      dot_char = partial_source.lines[dot_line].chomp.length

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => dot_line, "character" => dot_char }
      })

      labels = response.fetch("result").fetch("items").map { |i| i["label"] }
      assert_includes labels, "x"
    end
  end

  def test_completion_uses_ref_receiver_type_for_fields
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_ref_receiver_completion_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_REF_RECEIVER_COMPLETION }
      })

      partial_source = SOURCE_WITH_REF_RECEIVER_COMPLETION.sub("return rp.x", "return rp.")
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => partial_source }]
      })

      dot_line = partial_source.lines.index { |line| line.include?("return rp.") }
      dot_char = partial_source.lines[dot_line].chomp.length

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => dot_line, "character" => dot_char }
      })

      labels = response.fetch("result").fetch("items").map { |i| i["label"] }
      assert_includes labels, "x"
      assert_includes labels, "y"
    end
  end

  def test_completion_uses_pointer_receiver_type_for_fields
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_ptr_receiver_completion_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_POINTER_RECEIVER_COMPLETION }
      })

      partial_source = SOURCE_WITH_POINTER_RECEIVER_COMPLETION.sub("return pp.x", "return pp.")
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => partial_source }]
      })

      dot_line = partial_source.lines.index { |line| line.include?("return pp.") }
      dot_char = partial_source.lines[dot_line].chomp.length

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => dot_line, "character" => dot_char }
      })

      labels = response.fetch("result").fetch("items").map { |i| i["label"] }
      assert_includes labels, "x"
      assert_includes labels, "y"
    end
  end

  def test_completion_uses_top_level_value_receiver_type
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_top_level_value_receiver_completion_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_TOP_LEVEL_VALUE_RECEIVER_COMPLETION }
      })

      partial_source = SOURCE_WITH_TOP_LEVEL_VALUE_RECEIVER_COMPLETION.sub("return origin.x", "return origin.")
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => partial_source }]
      })

      dot_line = partial_source.lines.index { |line| line.include?("return origin.") }
      dot_char = partial_source.lines[dot_line].chomp.length

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => dot_line, "character" => dot_char }
      })

      labels = response.fetch("result").fetch("items").map { |i| i["label"] }
      assert_includes labels, "x"
      assert_includes labels, "y"
      assert_includes labels, "area"
    end
  end

  def test_hover_returns_method_info_for_method_name
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_method_hover_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_METHODS }
      })
      # Line 5 (0-based) is "    def zero() -> i32:", 'zero' starts at character 8.
      response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 5, "character" => 8 }
      })
      hover_value = response.dig("result", "contents", "value")
      assert_includes hover_value, "local zero"
      refute_includes hover_value, "-> i32"
    end
  end

  def test_code_lens_returns_function_signatures
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_codelens_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      response = client.send_request("textDocument/codeLens", {
        "textDocument" => { "uri" => uri }
      })
      lenses = response.fetch("result")
      assert_kind_of Array, lenses
      assert lenses.length >= 2, "expected at least 2 code lenses (add + main), got #{lenses.length}"
      titles = lenses.map { |l| l.dig("command", "title") }
      assert titles.any? { |t| t.include?("add") && t.include?("-> i32") }
      assert titles.any? { |t| t.include?("main") }
    end
  end

  def test_document_diagnostic_collects_errors_from_multiple_functions
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_multi_err_test.mt"
      source = <<~MT
        def foo() -> i32:
            return "not an int"

        def bar() -> bool:
            return 42
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/diagnostic", { "textDocument" => { "uri" => uri } })
      result = response.fetch("result")
      assert_equal "full", result["kind"]
      assert result["items"].length >= 2,
             "expected errors from both foo and bar, got #{result['items'].length}: #{result['items'].map { |i| i['message'] }.inspect}"
    end
  end

  def test_document_diagnostic_sema_errors_have_accurate_line_numbers
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_err_line_test.mt"
      source = <<~MT
        def ok(a: i32, b: i32) -> i32:
            return a + b

        def broken() -> i32:
            return "wrong type"
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/diagnostic", { "textDocument" => { "uri" => uri } })
      result = response.fetch("result")
      assert_equal "full", result["kind"]
      assert result["items"].length >= 1

      # "return 'wrong type'" is on source line 5 (1-based), LSP 0-based = 4.
      error_lines = result["items"].map { |i| i.dig("range", "start", "line") }
      assert_includes error_lines, 4,
                      "expected sema error on line 4 (0-based), got lines: #{error_lines.inspect}"
    end
  end

  def test_semantic_tokens_classify_imported_module_function_reference_as_function
    Dir.mktmpdir("mt_lsp_semantic_tokens") do |dir|
      c_dir = File.join(dir, "std", "c")
      FileUtils.mkdir_p(c_dir)

      File.write(File.join(c_dir, "sdl3.mt"), <<~MT)
        extern module std.c.sdl3:
            extern def SDL_SetWindowFillDocument(window: ptr[void], fill: bool) -> bool
      MT

      source_path = File.join(dir, "std", "sdl3.mt")
      FileUtils.mkdir_p(File.dirname(source_path))
      source = <<~MT
        module std.sdl3

        import std.c.sdl3 as c

        pub foreign def set_window_fill_document(window: ptr[void], fill: bool) -> bool = c.SDL_SetWindowFillDocument
      MT
      File.write(source_path, source)

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        alias_entry = semantic_entry_for_lexeme(source, entries, "c")
        member_entry = semantic_entry_for_lexeme(source, entries, "SDL_SetWindowFillDocument")

        assert_equal "namespace", alias_entry.fetch("tokenType")
        assert_equal "function", member_entry.fetch("tokenType")
      end
    end
  end

  private

  def test_code_action_quickfix_prefer_let
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_prefer_let.mt"
      source = <<~MT
        module demo.lint

        def main() -> i32:
            var x = 1
            return x
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      prefer_let_diag = {
        "source" => "milk-tea",
        "code"   => "prefer-let",
        "range"  => { "start" => { "line" => 3, "character" => 4 }, "end" => { "line" => 3, "character" => 13 } },
        "message" => "var 'x' is never reassigned; prefer 'let'"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 3, "character" => 0 }, "end" => { "line" => 3, "character" => 0 } },
        "context" => { "diagnostics" => [prefer_let_diag] }
      })

      actions = response.fetch("result")
      quickfix = actions.find { |a| a["code"] == "prefer-let" || a.dig("diagnostics", 0, "code") == "prefer-let" }
      assert quickfix, "expected a quickFix action for prefer-let"
      assert_equal "quickFix", quickfix["kind"]
      edit_text = quickfix.dig("edit", "changes", uri, 0, "newText")
      assert_match(/\blet\b/, edit_text)
      refute_match(/\bvar\b/, edit_text)
    end
  end

  def test_code_action_quickfix_redundant_else
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_redundant_else.mt"
      source = <<~MT
        module demo.lint

        def sign(n: i32) -> i32:
            if n > 0:
                return 1
            else:
                return -1
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      # The redundant-else warning fires on line 7 (1-based), which is `return -1`
      redundant_diag = {
        "source" => "milk-tea",
        "code"   => "redundant-else",
        "range"  => { "start" => { "line" => 6, "character" => 8 }, "end" => { "line" => 6, "character" => 17 } },
        "message" => "else block is redundant because all preceding branches return"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 6, "character" => 0 }, "end" => { "line" => 6, "character" => 0 } },
        "context" => { "diagnostics" => [redundant_diag] }
      })

      actions = response.fetch("result")
      quickfix = actions.find { |a| a["kind"] == "quickFix" && a["title"] == "Remove redundant else" }
      assert quickfix, "expected a quickFix action for redundant-else"
      edit_changes = quickfix.dig("edit", "changes", uri)
      assert_kind_of Array, edit_changes
      new_text = edit_changes.first["newText"]
      refute_match(/else:/, new_text)
      assert_match(/return -1/, new_text)
    end
  end

  def test_initialize_advertises_quickfix_code_action_kind
    with_server do |client|
      response = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      kinds = response.dig("result", "capabilities", "codeActionProvider", "codeActionKinds")
      assert_includes kinds, "quickFix"
      assert_includes kinds, "source.fixAll"
    end
  end

  def path_to_uri(path)
    escaped_path = path.split("/").map { |segment| CGI.escape(segment).gsub("+", "%20") }.join("/")
    "file://#{escaped_path}"
  end

  def decode_semantic_token_entries(data, legend)
    line = 0
    char = 0

    data.each_slice(5).map do |delta_line, delta_start, length, token_type_idx, modifier_bits|
      line += delta_line
      char = delta_line.zero? ? char + delta_start : delta_start

      {
        "line" => line,
        "startChar" => char,
        "endChar" => char + length,
        "tokenType" => legend.fetch("tokenTypes").fetch(token_type_idx),
        "modifierBits" => modifier_bits
      }
    end
  end

  def semantic_entry_for_lexeme(source, entries, lexeme)
    lines = source.lines
    entries.find do |entry|
      line_text = lines.fetch(entry.fetch("line"))
      line_text[entry.fetch("startChar"), lexeme.length] == lexeme
    end or flunk("expected semantic token entry for #{lexeme.inspect}")
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
