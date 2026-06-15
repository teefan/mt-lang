# frozen_string_literal: true

require_relative "helpers"

class LifecycleTest < Minitest::Test
  include LSPServerTestHelpers

  def test_shutdown_stops_background_diagnostics_workers
    server = MilkTea::LSP::Server.new(protocol: RecordingProtocol.new)
    workers = server.instance_variable_get(:@diagnostics_workers).dup

    refute_empty workers

    server.send(:stop_diagnostics_workers)

    assert workers.none?(&:alive?)
  end

  def test_initialize_advertises_expected_capabilities
    with_server do |client|
      response = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      capabilities = response.dig("result", "capabilities")

      assert_equal 2, capabilities.dig("textDocumentSync", "change")
      assert_equal true, capabilities["hoverProvider"]
      assert_equal true, capabilities["definitionProvider"]
      assert_equal true, capabilities["declarationProvider"]
      assert_equal true, capabilities["typeDefinitionProvider"]
      assert_equal true, capabilities["implementationProvider"]
      assert_equal true, capabilities["referencesProvider"]
      assert_kind_of Hash, capabilities["documentLinkProvider"]
      assert_equal true, capabilities["documentHighlightProvider"]
      assert_equal true, capabilities["documentRangeFormattingProvider"]
      assert_kind_of Hash, capabilities["codeActionProvider"]
      assert_equal true, capabilities["inlayHintProvider"]
      assert_kind_of Hash, capabilities["renameProvider"]
      assert_kind_of Hash, capabilities["signatureHelpProvider"]
      assert_kind_of Hash, capabilities["completionProvider"]
      assert_kind_of Hash, capabilities["codeLensProvider"]
      assert_equal true, capabilities["workspaceSymbolProvider"]
      workspace_folders = capabilities.dig("workspace", "workspaceFolders")
      assert_equal true, workspace_folders["supported"]
      assert_equal true, workspace_folders["changeNotifications"]
    end
  end

  def test_cancel_request_replies_with_request_cancelled_error
    protocol = RecordingProtocol.new
    server = MilkTea::LSP::Server.new(protocol: protocol)

    server.send(:process_message, {
      "jsonrpc" => "2.0",
      "method" => "$/cancelRequest",
      "params" => { "id" => 99 }
    })
    server.send(:process_message, {
      "jsonrpc" => "2.0",
      "id" => 99,
      "method" => "initialize",
      "params" => { "rootUri" => nil, "capabilities" => {} }
    })

    assert_equal [], protocol.responses
    error = protocol.errors.find { |entry| entry["id"] == 99 }
    refute_nil error
    assert_equal(-32_800, error["code"])
    assert_equal("Request cancelled", error["message"])
  ensure
    server&.send(:handle_shutdown, nil)
  end

  def test_run_skips_invalid_messages_and_processes_following_requests
    protocol = ScriptedProtocol.new([
      MilkTea::LSP::Protocol::INVALID_MESSAGE,
      {
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => { "rootUri" => nil, "capabilities" => {} }
      },
      nil,
    ])

    server = MilkTea::LSP::Server.new(protocol: protocol)
    server.run

    response = protocol.responses.find { |entry| entry["id"] == 1 }
    refute_nil response
    capabilities = response.fetch("result")[:capabilities] || response.fetch("result")["capabilities"]
    assert_kind_of Hash, capabilities
    assert_equal [], protocol.errors
  ensure
    server&.send(:handle_shutdown, nil)
  end

  def test_workspace_folder_change_updates_workspace_root_and_reindexes
    Dir.mktmpdir("milk-tea-lsp-workspace-folder-change") do |dir|
      first_root = File.join(dir, "first")
      second_root = File.join(dir, "second")
      FileUtils.mkdir_p(first_root)
      FileUtils.mkdir_p(second_root)
      File.write(File.join(second_root, "new_symbol.mt"), <<~MT)
        function folder_changed_symbol() -> int:
            return 1
      MT

      first_root_uri = path_to_uri(first_root)
      second_root_uri = path_to_uri(second_root)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => first_root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})

        before = client.send_request("workspace/symbol", { "query" => "folder_changed_symbol" })
        assert_equal [], before.fetch("result")

        client.send_notification("workspace/didChangeWorkspaceFolders", {
          "event" => {
            "added" => [{ "uri" => second_root_uri, "name" => "second" }],
            "removed" => [{ "uri" => first_root_uri, "name" => "first" }],
          }
        })

        after = client.send_request("workspace/symbol", { "query" => "folder_changed_symbol" })
        names = after.fetch("result").map { |symbol| symbol["name"] }
        assert_includes names, "folder_changed_symbol"
      end
    end
  end

  def test_document_symbol_and_hover_work_after_open
    with_shared_server do |client|
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
        "position" => { "line" => 4, "character" => 9 }
      })
      hover_value = hover_response.dig("result", "contents", "value")
      assert_includes hover_value, "add"
      assert_includes hover_value, "-> int"
    end
  end

  def test_document_symbol_includes_event_declarations
    source = <<~MT
      event reloaded[4]

      struct Window:
          public event closed[4]
          title: str

      function main() -> void:
          reloaded.emit()
    MT

    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_event_symbols_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/documentSymbol", {
        "textDocument" => { "uri" => uri }
      })

      symbols = response.fetch("result")
      names = symbols.map { |symbol| symbol["name"] }
      assert_includes names, "reloaded"
      assert_includes names, "main"

      window = symbols.find { |s| s["name"] == "Window" }
      refute_nil window
      refute_nil window["children"]
      child_names = window["children"].map { |c| c["name"] }
      assert_includes child_names, "closed"
      assert_includes child_names, "title"
    end
  end

  def test_document_symbols_are_wrapped_in_module_hierarchy
    Dir.mktmpdir("mt-lsp-outline-module") do |dir|
      engine_dir = File.join(dir, "engine")
      FileUtils.mkdir_p(engine_dir)
      File.write(File.join(dir, "package.toml"), "[package]\nname = \"test\"\nsource_root = \".\"\n")
      path = File.join(engine_dir, "math.mt")
      source = <<~MT
        public function add(a: int, b: int) -> int:
            return a + b

        public struct Vec2:
            x: float
            y: float
      MT
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/documentSymbol", {
          "textDocument" => { "uri" => uri }
        })
        result = response.fetch("result")

        assert_equal 1, result.length, "top-level should have 1 module node"
        assert_equal "engine", result[0]["name"]
        assert_equal 2, result[0]["kind"], "module kind should be 2"

        math = result[0]["children"]
        assert_equal 1, math.length
        assert_equal "math", math[0]["name"]
        assert_equal 2, math[0]["kind"]

        children_names = math[0]["children"].map { |c| c["name"] }
        assert_includes children_names, "add"
        assert_includes children_names, "Vec2"
      end
    end
  end

  def test_document_symbols_no_wrapping_for_single_segment_module
    Dir.mktmpdir("mt-lsp-outline-flat") do |dir|
      path = File.join(dir, "standalone.mt")
      source = <<~MT
        public function add(a: int, b: int) -> int:
            return a + b

        public struct Vec2:
            x: float
            y: float
      MT
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/documentSymbol", {
          "textDocument" => { "uri" => uri }
        })
        result = response.fetch("result")

        names = result.map { |s| s["name"] }
        assert_includes names, "add", "single-segment modules should have flat top-level symbols"
        assert_includes names, "Vec2"
        refute names.include?("standalone"), "standalone module name should NOT wrap when single segment"
      end
    end
  end

  def test_document_link_resolves_existing_relative_resource_path_string
    Dir.mktmpdir("milk-tea-lsp-doc-link") do |dir|
      assets_dir = File.join(dir, "assets")
      Dir.mkdir(assets_dir)

      asset_path = File.join(assets_dir, "raybunny.png")
      File.binwrite(asset_path, "png")

      main_path = File.join(dir, "main.mt")
      source = <<~MT
        const bunny_path: str = "./assets/raybunny.png"
        const title: str = "Milk Tea Bunnymark"
      MT
      File.write(main_path, source)

      root_uri = path_to_uri(dir)
      main_uri = path_to_uri(main_path)
      asset_uri = path_to_uri(asset_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source
          }
        })

        response = client.send_request("textDocument/documentLink", {
          "textDocument" => { "uri" => main_uri }
        })

        links = response.fetch("result")
        assert_equal 1, links.length
        assert_equal asset_uri, links[0]["target"]
        assert_equal 0, links[0].dig("range", "start", "line")
      end
    end
  end

  def test_document_symbol_captures_opaque_declarations
    with_shared_server do |client|
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

  def test_document_symbol_captures_interface_declarations_with_interface_kind
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_interface_symbol_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_LOCAL_INTERFACES }
      })

      response = client.send_request("textDocument/documentSymbol", { "textDocument" => { "uri" => uri } })
      symbol = response.fetch("result").find { |entry| entry["name"] == "ScreenState" }

      refute_nil symbol
      assert_equal 11, symbol["kind"]
    end
  end

  def test_code_lens_returns_lenses_for_functions
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_codelens_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      response = client.send_request("textDocument/codeLens", {
        "textDocument" => { "uri" => uri }
      })
      lenses = response.fetch("result")
      names = lenses.map { |lens| lens.dig("data", "name") }
      assert_equal 2, lenses.length
      assert_includes names, "add"
      assert_includes names, "main"
    end
  end

end
