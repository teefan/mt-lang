# frozen_string_literal: true

require_relative "helpers"

class DiagnosticsTest < Minitest::Test
  include LSPServerTestHelpers

  def test_did_save_republishes_diagnostics
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_save_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => "struct Vec2:\n    x: float\n" }
      })
      client.send_notification("textDocument/didSave", { "textDocument" => { "uri" => uri } })
      # Server still alive if we get a response to a followup request
      response = client.send_request("textDocument/documentSymbol", { "textDocument" => { "uri" => uri } })
      assert_kind_of Array, response.fetch("result")
    end
  end

  def test_publish_diagnostics_uses_fast_mode_on_change_and_full_on_open_save
    protocol = RecordingProtocol.new
    server = MilkTea::LSP::Server.new(protocol: protocol)
    uri = "file:///tmp/lsp_fast_publish_diagnostics.mt"
    source = <<~MT
      function main(value: int) -> int:
          unsafe:
              let copy = value + 1
          return int<-value
    MT

    observed_tiers = Queue.new
    workspace = server.instance_variable_get(:@workspace)
    workspace.define_singleton_method(:collect_diagnostics) do |_uri, lint_tier: :full|
      observed_tiers << lint_tier
      []
    end

    server.send(:handle_did_open, {
      "textDocument" => {
        "uri" => uri,
        "text" => source,
      }
    })

    Timeout.timeout(5) do
      loop do
        message = protocol.notifications.pop
        break message if message.dig("method") == "textDocument/publishDiagnostics" && message.dig("params", :uri) == uri
      end
    end


    server.send(:handle_did_change, {
      "textDocument" => {
        "uri" => uri,
      },
      "contentChanges" => [{
        "text" => source.sub("copy", "local_copy"),
      }],
    })

    Timeout.timeout(5) do
      loop do
        message = protocol.notifications.pop
        break message if message.dig("method") == "textDocument/publishDiagnostics" && message.dig("params", :uri) == uri
      end
    end


    server.send(:handle_did_save, {
      "textDocument" => {
        "uri" => uri,
      }
    })

    Timeout.timeout(5) do
      loop do
        message = protocol.notifications.pop
        break message if message.dig("method") == "textDocument/publishDiagnostics" && message.dig("params", :uri) == uri
      end
    end

    assert_equal :full, observed_tiers.pop
    assert_equal :fast, observed_tiers.pop
    assert_equal :full, observed_tiers.pop

  ensure
    server&.send(:handle_shutdown, nil)
  end

  def test_did_change_refreshes_open_dependency_caches_only_when_imports_change
    protocol = RecordingProtocol.new
    server = MilkTea::LSP::Server.new(protocol: protocol)
    workspace = server.instance_variable_get(:@workspace)
    refresh_calls = Queue.new

    workspace.define_singleton_method(:refresh_open_document_dependency_caches) do |changed_uri|
      refresh_calls << changed_uri
      []
    end

    uri = "file:///tmp/lsp_import_refresh_gate.mt"
    source = <<~MT
      import demo.math as math

      function main() -> int:
          return math.answer()
    MT

    server.send(:handle_did_open, {
      "textDocument" => {
        "uri" => uri,
        "text" => source,
      }
    })

    server.send(:handle_did_change, {
      "textDocument" => { "uri" => uri },
      "contentChanges" => [{
        "text" => source.sub("return math.answer()", "let value = math.answer()\n    return value"),
      }],
    })

    assert refresh_calls.empty?

    server.send(:handle_did_change, {
      "textDocument" => { "uri" => uri },
      "contentChanges" => [{
        "text" => source.sub("import demo.math as math", "import demo.math as math\nimport demo.extra as extra"),
      }],
    })

    assert_equal uri, Timeout.timeout(5) { refresh_calls.pop }
  ensure
    server&.send(:handle_shutdown, nil)
  end

  def test_perf_log_context_includes_short_uri_for_threshold_logs
    server = MilkTea::LSP::Server.new
    root_path = File.join(Dir.tmpdir, "milk-tea-lsp-perf")
    source_path = File.join(root_path, "demo", "slow.mt")
    FileUtils.mkdir_p(File.dirname(source_path))

    server.instance_variable_set(:@root_uri, path_to_uri(root_path))

    detail = server.send(:perf_log_context, 'textDocument/didOpen', {
      "textDocument" => { "uri" => path_to_uri(source_path) }
    }, verbose: false)

    assert_equal " uri=demo/slow.mt", detail
  ensure
    server&.send(:handle_shutdown, nil)
  end

  def test_background_document_context_skips_diagnostics_until_promoted
    protocol = RecordingProtocol.new
    server = MilkTea::LSP::Server.new(protocol: protocol)
    uri = "file:///tmp/lsp_background_context.mt"
    source = <<~MT
      function main() -> int:
          return 0
    MT

    server.send(:handle_document_context, {
      "textDocument" => { "uri" => uri },
      "source" => "background-document"
    })
    server.send(:handle_did_open, {
      "textDocument" => { "uri" => uri, "text" => source }
    })

    refute_includes server.instance_variable_get(:@diagnostics_last_scheduled_hash).keys, uri

    server.send(:handle_document_context, {
      "textDocument" => { "uri" => uri },
      "source" => "active-editor"
    })

    assert_includes server.instance_variable_get(:@diagnostics_last_scheduled_hash).keys, uri

    published = Timeout.timeout(5) do
      loop do
        message = protocol.notifications.pop
        break message if message.dig("method") == "textDocument/publishDiagnostics" && message.dig("params", :uri) == uri
      end
    end

    assert_equal "textDocument/publishDiagnostics", published.fetch("method")
    assert_equal uri, published.dig("params", :uri)
  ensure
    server&.send(:handle_shutdown, nil)
  end

  def test_watched_file_change_skips_diagnostics_for_background_documents
    protocol = RecordingProtocol.new
    server = MilkTea::LSP::Server.new(protocol: protocol)

    Dir.mktmpdir("milk-tea-lsp-watch-background") do |dir|
      lib_path = File.join(dir, "mathx.mt")
      main_path = File.join(dir, "main.mt")

      File.write(lib_path, <<~MT)
        public function greet() -> int:
            return 1
      MT

      main_source = <<~MT
        import mathx as mx

        function main() -> int:
            return mx.greet()
      MT
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      lib_uri = path_to_uri(lib_path)
      main_uri = path_to_uri(main_path)

      server.send(:handle_initialize, { "rootUri" => root_uri, "capabilities" => {} })
      server.send(:handle_initialized, {})
      server.send(:handle_document_context, {
        "textDocument" => { "uri" => main_uri },
        "source" => "background-document"
      })
      server.send(:handle_did_open, {
        "textDocument" => {
          "uri" => main_uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => main_source
        }
      })

      refute_includes server.instance_variable_get(:@diagnostics_last_scheduled_hash).keys, main_uri

      File.write(lib_path, <<~MT)
        public function greet() -> str:
            return "oops"
      MT

      server.send(:handle_did_change_watched_files, {
        "changes" => [{ "uri" => lib_uri, "type" => 2 }]
      })

      refute_includes server.instance_variable_get(:@diagnostics_last_scheduled_hash).keys, main_uri
    end
  ensure
    server&.send(:handle_shutdown, nil)
  end

  def test_document_diagnostic_returns_full_report
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_doc_diag_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => "function add(a: int, b: int) -> int:\n    return a + b\n"
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
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_doc_diag_err_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => "function bad(\n"
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
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_doc_diag_unchanged_test.mt"
      source = "function add(a: int, b: int) -> int:\n    return a + b\n"
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
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_doc_diag_change_test.mt"
      source = "function add(a: int, b: int) -> int:\n    return a + b\n"
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

      changed = "function add(a: int, b: int) -> int:\n    return a - b\n"
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

  def test_document_diagnostic_strict_current_root_diagnostics_can_be_enabled_live
    Dir.mktmpdir("milk-tea-lsp-strict-current-root") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      dependency_path = File.join(dir, "dep.mt")
      main_path = File.join(dir, "main.mt")

      File.write(dependency_path, <<~MT)
        public function answer() -> int:
            return 42

        public function broken() -> int:
            return "wrong type"
      MT

      main_source = <<~MT
        import dep as dep

        function main() -> int:
            return dep.answer()
      MT
      File.write(main_path, main_source)

      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        initial = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        assert_equal [], initial.fetch("result").fetch("items")

        client.send_notification("workspace/didChangeConfiguration", {
          "settings" => {
            "milkTea" => {
              "lsp" => {
                "strictCurrentRootDiagnostics" => true
              }
            }
          }
        })

        updated = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        items = updated.fetch("result").fetch("items")
        strict_root = items.find { |item| item.dig("data", "stage") == "strict-root" }

        refute_nil strict_root, "expected strict-root diagnostic, got: #{items.inspect}"
        assert_includes strict_root.fetch("message"), "strict current-root check failed"
        assert_match(/return type mismatch|wrong type/, strict_root.fetch("message"))
      end
    end
  end

  def test_document_diagnostic_strict_current_root_diagnostics_reports_invalid_entrypoint
    Dir.mktmpdir("milk-tea-lsp-strict-entrypoint") do |dir|
      FileUtils.mkdir_p(File.join(dir, "std"))
      path = File.join(dir, "main.mt")
      source = <<~MT
        function main(value: int) -> int:
            return value
      MT
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", {
          "rootUri" => path_to_uri(dir),
          "capabilities" => {},
          "initializationOptions" => {
            "milkTea" => {
              "lsp" => {
                "strictCurrentRootDiagnostics" => true
              }
            }
          }
        })

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => uri }
        })
        items = response.fetch("result").fetch("items")
        strict_root = items.find { |item| item.dig("data", "stage") == "strict-root" }

        refute_nil strict_root, "expected strict-root diagnostic, got: #{items.inspect}"
        assert_equal "build/error", strict_root.fetch("code")
        assert_includes strict_root.fetch("message"), "root main is not a valid executable entrypoint"
      end
    end
  end

  def test_document_diagnostic_refreshes_after_imported_module_watched_change
    Dir.mktmpdir("milk-tea-lsp-watch-diagnostics") do |dir|
      Dir.mkdir(File.join(dir, "std"))

      lib_path = File.join(dir, "mathx.mt")
      main_path = File.join(dir, "main.mt")

      File.write(lib_path, <<~MT)
        public function greet() -> int:
            return 1
      MT
      main_source = <<~MT
        import mathx as mx

        function main() -> int:
            return mx.greet()
      MT
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

        first = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        first_result = first.fetch("result")
        assert_equal "full", first_result["kind"]
        assert_equal [], first_result["items"]

        File.write(lib_path, <<~MT)
          public function greet() -> str:
              return "oops"
        MT

        client.send_notification("workspace/didChangeWatchedFiles", {
          "changes" => [{ "uri" => lib_uri, "type" => 2 }]
        })

        second = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri },
          "previousResultId" => first_result["resultId"]
        })
        second_result = second.fetch("result")

        assert_equal "full", second_result["kind"]
        refute_equal first_result["resultId"], second_result["resultId"]
        assert_operator second_result.fetch("items").length, :>=, 1
      end
    end
  end

  def test_document_diagnostic_refreshes_after_imported_module_watched_create
    Dir.mktmpdir("milk-tea-lsp-watch-create-diagnostics") do |dir|
      Dir.mkdir(File.join(dir, "std"))

      lib_path = File.join(dir, "mathx.mt")
      main_path = File.join(dir, "main.mt")

      main_source = <<~MT
        import mathx as mx

        function main() -> int:
            return mx.greet()
      MT
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

        first = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        first_result = first.fetch("result")
        first_messages = first_result.fetch("items").map { |item| item["message"] }
        assert first_messages.any? { |message| message.include?("module not found") }

        File.write(lib_path, <<~MT)
          public function greet() -> int:
              return 1
        MT

        client.send_notification("workspace/didChangeWatchedFiles", {
          "changes" => [{ "uri" => lib_uri, "type" => 1 }]
        })

        second = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri },
          "previousResultId" => first_result["resultId"]
        })
        second_result = second.fetch("result")

        assert_equal "full", second_result["kind"]
        refute_equal first_result["resultId"], second_result["resultId"]
        assert_equal [], second_result.fetch("items")
      end
    end
  end

  def test_document_diagnostic_refreshes_after_imported_module_watched_delete
    Dir.mktmpdir("milk-tea-lsp-watch-delete-diagnostics") do |dir|
      Dir.mkdir(File.join(dir, "std"))

      lib_path = File.join(dir, "mathx.mt")
      main_path = File.join(dir, "main.mt")

      File.write(lib_path, <<~MT)
        public function greet() -> int:
            return 1
      MT
      main_source = <<~MT
        import mathx as mx

        function main() -> int:
            return mx.greet()
      MT
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

        first = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        first_result = first.fetch("result")
        assert_equal [], first_result.fetch("items")

        File.delete(lib_path)

        client.send_notification("workspace/didChangeWatchedFiles", {
          "changes" => [{ "uri" => lib_uri, "type" => 3 }]
        })

        second = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri },
          "previousResultId" => first_result["resultId"]
        })
        second_result = second.fetch("result")
        second_messages = second_result.fetch("items").map { |item| item["message"] }

        assert_equal "full", second_result["kind"]
        refute_equal first_result["resultId"], second_result["resultId"]
        assert second_messages.any? { |message| message.include?("module not found") }
      end
    end
  end

  def test_document_diagnostic_refreshes_after_imported_module_did_change
    Dir.mktmpdir("milk-tea-lsp-didchange-diagnostics") do |dir|
      Dir.mkdir(File.join(dir, "std"))
      helper_path = File.join(dir, "helper.mt")
      main_path = File.join(dir, "main.mt")

      helper_initial = <<~MT
      MT
      helper_updated = <<~MT
        extending str:
            public function excited() -> int:
                return 1
      MT
      main_source = <<~MT
        import helper as helper

        function main() -> int:
            return "milk".excited()
      MT

      File.write(helper_path, helper_initial)
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      helper_uri = path_to_uri(helper_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => helper_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => helper_initial
          }
        })
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        first = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        first_result = first.fetch("result")
        first_codes = first_result.fetch("items").map { |item| item["code"] }

        assert_equal "full", first_result["kind"]
        assert_operator first_result.fetch("items").length, :>=, 1
        assert_includes first_codes, "sema/error"

        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => helper_uri, "version" => 2 },
          "contentChanges" => [{ "text" => helper_updated }]
        })

        second = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri },
          "previousResultId" => first_result["resultId"]
        })
        second_result = second.fetch("result")
        second_codes = second_result.fetch("items").map { |item| item["code"] }

        assert_equal "full", second_result["kind"]
        refute_equal first_result["resultId"], second_result["resultId"]
        refute_includes second_codes, "sema/error"
      end
    end
  end

  def test_document_diagnostic_locked_uses_package_lock_when_manifest_dependencies_drift
    Dir.mktmpdir("milk-tea-lsp-locked-diagnostics") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      ui_src_dir = File.join(ui_root, "src", "teefan", "ui")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "0.3.0"
        kind = "library"
        source_root = "src"
      TOML

      main_source = <<~MT
        import teefan.ui.layout as layout

        function main() -> int:
            let value = layout.default_width()
            unsafe:
                let copy = value + 1
            return value
      MT

      File.write(File.join(app_src_dir, "main.mt"), main_source)
      File.write(File.join(ui_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      MilkTea::PackageLock.write(app_root)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"
      TOML

      root_uri = path_to_uri(dir)
      main_path = File.join(app_src_dir, "main.mt")
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", {
          "rootUri" => root_uri,
          "capabilities" => {},
          "initializationOptions" => {
            "milkTea" => {
              "lsp" => {
                "dependencyResolution" => "locked"
              }
            }
          }
        })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        response = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        result = response.fetch("result")
        items = result.fetch("items")
        messages = items.map { |item| item["message"] }

        refute messages.any? { |message| message.match?(/module not found|package dependency not declared/) },
               "expected locked diagnostics to avoid live-manifest import failures, got: #{messages.inspect}"
      end
    end
  end

  def test_document_diagnostic_frozen_reports_stale_package_lock
    Dir.mktmpdir("milk-tea-lsp-frozen-diagnostics") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      ui_src_dir = File.join(ui_root, "src", "teefan", "ui")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"

        [dependencies]
        "teefan.ui" = { path = "../../libs/ui" }
      TOML

      File.write(File.join(ui_root, "package.toml"), <<~TOML)
        [package]
        name = "teefan.ui"
        version = "0.3.0"
        kind = "library"
        source_root = "src"
      TOML

      main_source = <<~MT
        import teefan.ui.layout as layout

        function main() -> int:
            let value = layout.default_width()
            unsafe:
                let copy = value + 1
            return value
      MT

      File.write(File.join(app_src_dir, "main.mt"), main_source)
      File.write(File.join(ui_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      MilkTea::PackageLock.write(app_root)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"
      TOML

      root_uri = path_to_uri(dir)
      main_path = File.join(app_src_dir, "main.mt")
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", {
          "rootUri" => root_uri,
          "capabilities" => {},
          "initializationOptions" => {
            "milkTea" => {
              "lsp" => {
                "dependencyResolution" => "frozen"
              }
            }
          }
        })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        response = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        result = response.fetch("result")
        items = result.fetch("items")
        messages = items.map { |item| item["message"] }

        assert messages.any? { |message| message.include?("package.lock is out of date") },
               "expected frozen diagnostics to report stale package.lock, got: #{messages.inspect}"
      end
    end
  end

  def test_document_diagnostic_platform_override_uses_platform_specific_import_variant_from_initialize
    Dir.mktmpdir("milk-tea-lsp-platform-diagnostics") do |dir|
      main_path = File.join(dir, "main.mt")
      support_path = File.join(dir, "support.mt")
      support_windows_path = File.join(dir, "support.windows.mt")

      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "demo"
      TOML

      main_source = <<~MT
        import support

        function main() -> int:
            return support.value()
      MT

      File.write(main_path, main_source)
      File.write(support_path, <<~MT)
      MT
      File.write(support_windows_path, <<~MT)
        public function value() -> int:
            return 2
      MT

      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", {
          "rootUri" => path_to_uri(dir),
          "capabilities" => {},
          "initializationOptions" => {
            "milkTea" => {
              "lsp" => {
                "platform" => "windows"
              }
            }
          }
        })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        response = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        items = response.fetch("result").fetch("items")
        messages = items.map { |item| item["message"] }

        refute messages.any? { |message| message.match?(/function not found|value/) },
               "expected windows platform override to resolve support.windows.mt, got: #{messages.inspect}"
      end
    end
  end

  def test_document_diagnostic_platform_override_updates_live_via_did_change_configuration
    Dir.mktmpdir("milk-tea-lsp-platform-live-change") do |dir|
      main_path = File.join(dir, "main.mt")
      support_path = File.join(dir, "support.mt")
      support_windows_path = File.join(dir, "support.windows.mt")

      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "demo"
      TOML

      main_source = <<~MT
        import support

        function main() -> int:
            return support.value()
      MT

      File.write(main_path, main_source)
      File.write(support_path, <<~MT)
      MT
      File.write(support_windows_path, <<~MT)
        public function value() -> int:
            return 2
      MT

      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", {
          "rootUri" => path_to_uri(dir),
          "capabilities" => {}
        })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        initial_response = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        initial_messages = initial_response.fetch("result").fetch("items").map { |item| item["message"] }
        assert initial_messages.any? { |message| message.match?(/function not found|value/) },
               "expected shared-platform diagnostics before override, got: #{initial_messages.inspect}"

        client.send_notification("workspace/didChangeConfiguration", {
          "settings" => {
            "milkTea" => {
              "lsp" => {
                "platform" => "windows"
              }
            }
          }
        })

        updated_response = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        updated_messages = updated_response.fetch("result").fetch("items").map { |item| item["message"] }

        refute updated_messages.any? { |message| message.match?(/function not found|value/) },
               "expected live platform override to invalidate diagnostics caches, got: #{updated_messages.inspect}"
      end
    end
  end

  def test_diagnostic_with_std_fs_import_honors_configured_platform
    Dir.mktmpdir("milk-tea-lsp-platform-std-fs") do |dir|
      main_path = File.join(dir, "main.mt")

      File.write(File.join(dir, "package.toml"), <<~TOML)
        [package]
        name = "demo"
      TOML

      main_source = <<~MT
        import std.fs as fs

        function main() -> int:
            var temp = fs.temporary_directory()
            defer temp.release()
            return 0
      MT

      File.write(main_path, main_source)
      main_uri = path_to_uri(main_path)
      with_server do |client|
        client.send_request("initialize", {
          "rootUri" => path_to_uri(dir),
          "capabilities" => {},
          "initializationOptions" => {
            "milkTea" => {
              "lsp" => {
                "platform" => "windows"
              }
            }
          }
        })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        diagnostic = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        items = diagnostic.fetch("result").fetch("items")
        messages = items.map { |item| item["message"] }

        refute messages.any? { |message| message.match?(/function not found|temporary_directory/) },
               "expected configured platform diagnostics to resolve std.fs members, got: #{messages.inspect}"
      end
    end
  end

  def test_diagnostics_do_not_report_unsafe_requirement_inside_invalid_unsafe_block
    Dir.mktmpdir("milk-tea-lsp-invalid-unsafe-diagnostics") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        struct Counter:
            value: int

        function main() -> int:
            var counter = Counter(value = 3)
            let counter_ptr = ptr_of(counter)
            unsafe
                return read(counter_ptr).value
      MT
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source,
          },
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => uri },
        })
        messages = diagnostics.fetch("result").fetch("items").map { |item| item.fetch("message") }

        assert messages.any? { |message| message.include?("expected ':' after unsafe") }
        refute messages.any? { |message| message.include?("raw pointer dereference requires unsafe") }
      end
    end
  end

  def test_document_diagnostic_collects_errors_from_multiple_functions
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_multi_err_test.mt"
      source = <<~MT
        function foo() -> int:
            return "not an int"

        function bar() -> bool:
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
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_err_line_test.mt"
      source = <<~MT
        function ok(a: int, b: int) -> int:
            return a + b

        function broken() -> int:
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

  def test_document_diagnostic_reports_attribute_target_errors_at_attribute_name
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_attribute_target_error_test.mt"
      source = <<~MT
        public attribute[field] rename(name: str)

        @[rename("packet")]
        struct Packet:
            payload_len: uint
      MT

      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/diagnostic", { "textDocument" => { "uri" => uri } })
      items = response.fetch("result").fetch("items")
      diagnostic = items.find { |item| item.fetch("message").include?("attribute rename cannot target struct") }

      refute_nil diagnostic, "expected attribute target diagnostic, got #{items.map { |item| item['message'] }.inspect}"
      assert_equal 2, diagnostic.dig("range", "start", "line")
      assert_equal 2, diagnostic.dig("range", "start", "character")
      assert_equal 8, diagnostic.dig("range", "end", "character")
    end
  end

  def test_document_diagnostic_reports_ambiguous_imported_extension_method_at_member_token
    Dir.mktmpdir("milk-tea-lsp-ambiguous-extension") do |dir|
      Dir.mkdir(File.join(dir, "std"))
      demo_dir = File.join(dir, "demo")
      FileUtils.mkdir_p(demo_dir)

      File.write(File.join(demo_dir, "dep.mt"), <<~MT)
        public struct Counter:
            value: int
      MT

      File.write(File.join(demo_dir, "a.mt"), <<~MT)
        import demo.dep as dep

        extending dep.Counter:
            public function tag() -> int:
                return 1
      MT

      File.write(File.join(demo_dir, "b.mt"), <<~MT)
        import demo.dep as dep

        extending dep.Counter:
            public function tag() -> int:
                return 2
      MT

      main_path = File.join(demo_dir, "main.mt")
      source = <<~MT
        import demo.dep as dep
        import demo.a as a
        import demo.b as b

        function main(value: dep.Counter) -> int:
            value.tag()
            return 0
      MT
      File.write(main_path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(main_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/diagnostic", { "textDocument" => { "uri" => uri } })
        items = response.fetch("result").fetch("items")
        diagnostic = items.find do |item|
          item.fetch("message").include?("ambiguous imported method demo.dep.Counter.tag")
        end

        refute_nil diagnostic, "expected ambiguous imported method diagnostic, got #{items.map { |item| item['message'] }.inspect}"
        assert_equal 5, diagnostic.dig("range", "start", "line")
        assert_equal 10, diagnostic.dig("range", "start", "character")
        assert_equal 11, diagnostic.dig("range", "end", "character")
      end
    end
  end

  def test_document_diagnostic_imported_module_non_export_edit_returns_unchanged
    Dir.mktmpdir("milk-tea-lsp-didchange-diagnostics-non-export") do |dir|
      Dir.mkdir(File.join(dir, "std"))
      helper_path = File.join(dir, "helper.mt")
      main_path = File.join(dir, "main.mt")

      helper_initial = <<~MT
        public function answer() -> int:
            return 1
      MT
      helper_updated = <<~MT
        public function answer() -> int:
            return 2
      MT
      main_source = <<~MT
        import helper as helper

        function main() -> int:
            return helper.answer()
      MT

      File.write(helper_path, helper_initial)
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      helper_uri = path_to_uri(helper_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => helper_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => helper_initial
          }
        })
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source
          }
        })

        first = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        first_result = first.fetch("result")
        assert_equal "full", first_result.fetch("kind")

        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => helper_uri, "version" => 2 },
          "contentChanges" => [{ "text" => helper_updated }]
        })

        second = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri },
          "previousResultId" => first_result.fetch("resultId")
        })
        second_result = second.fetch("result")

        assert_equal "unchanged", second_result.fetch("kind")
        assert_equal first_result.fetch("resultId"), second_result.fetch("resultId")
      end
    end
  end

end
