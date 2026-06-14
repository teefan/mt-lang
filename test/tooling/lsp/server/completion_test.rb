# frozen_string_literal: true

require_relative "helpers"

class CompletionTest < Minitest::Test
  include LSPServerTestHelpers

  def test_completion_locked_uses_package_lock_when_manifest_dependencies_drift
    Dir.mktmpdir("milk-tea-lsp-locked-completion") do |dir|
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
        import teefan.ui.layout as duel_ui

        function main() -> int:
            return duel_ui.default_width()
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
      partial_source = main_source.sub("return duel_ui.default_width()", "return duel_ui.")
      dot_line = partial_source.lines.index { |line| line.include?("return duel_ui.") }
      dot_char = partial_source.lines.fetch(dot_line).chomp.length

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
        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => main_uri, "version" => 2 },
          "contentChanges" => [{ "text" => partial_source }]
        })

        response = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => dot_line, "character" => dot_char }
        })
        result = response.fetch("result")
        items = result.fetch("items")
        labels = items.map { |item| item["label"] }
        default_width = items.find { |item| item["label"] == "default_width" }

        assert_includes labels, "default_width"
        assert_equal 3, default_width.fetch("kind")
      end
    end
  end

  def test_completion_works_for_file_backed_local_value_receiver_after_invalid_last_statement
    Dir.mktmpdir("milk-tea-lsp-file-backed-error-stmt-completion") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        struct Point:
            x: int
            y: int

        extending Point:
            function length() -> int:
                return this.x + this.y

        function main() -> int:
            let p = Point(x = 1, y = 2)
            return p.
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
        assert messages.any? { |message| message.include?("expected member name after '.'") }

        dot_line = source.lines.index { |line| line.include?("return p.") }
        dot_char = source.lines.fetch(dot_line).chomp.length

        completion = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => dot_line, "character" => dot_char },
        })
        items = completion.fetch("result").fetch("items")
        labels = items.map { |item| item.fetch("label") }
        kinds_by_label = items.to_h { |item| [item.fetch("label"), item.fetch("kind")] }

        assert_includes labels, "x"
        assert_includes labels, "y"
        assert_includes labels, "length"
        assert_equal 10, kinds_by_label["x"]
        assert_equal 2, kinds_by_label["length"]
      end
    end
  end

  def test_completion_uses_flow_refined_type_inside_invalid_if_block
    Dir.mktmpdir("milk-tea-lsp-invalid-if-flow-completion") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        struct Point:
            x: int

        function main() -> int:
            var p: Point? = null
            if p != null
                return p.
            return 0
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
        assert messages.any? { |message| message.include?("expected ':' before block") }

        dot_line = source.lines.index { |line| line.include?("return p.") }
        dot_char = source.lines.fetch(dot_line).chomp.length

        completion = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => dot_line, "character" => dot_char },
        })
        labels = completion.fetch("result").fetch("items").map { |item| item.fetch("label") }

        assert_includes labels, "x"
      end
    end
  end

  def test_completion_uses_flow_refined_type_inside_invalid_while_block
    Dir.mktmpdir("milk-tea-lsp-invalid-while-flow-completion") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        struct Point:
            x: int

        function main() -> int:
            var p: Point? = Point(x = 1)
            while p != null
                return p.
            return 0
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
        assert messages.any? { |message| message.include?("expected ':' before block") }

        dot_line = source.lines.index { |line| line.include?("return p.") }
        dot_char = source.lines.fetch(dot_line).chomp.length

        completion = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => dot_line, "character" => dot_char },
        })
        labels = completion.fetch("result").fetch("items").map { |item| item.fetch("label") }

        assert_includes labels, "x"
      end
    end
  end

  def test_completion_uses_for_binding_inside_invalid_for_block
    Dir.mktmpdir("milk-tea-lsp-invalid-for-completion") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        struct Point:
            x: int

        function main() -> int:
            let items = array[Point, 1](Point(x = 1))
            for item in items
                return item.
            return 0
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
        assert messages.any? { |message| message.include?("expected ':' before block") }

        dot_line = source.lines.index { |line| line.include?("return item.") }
        dot_char = source.lines.fetch(dot_line).chomp.length

        completion = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => dot_line, "character" => dot_char },
        })
        labels = completion.fetch("result").fetch("items").map { |item| item.fetch("label") }

        assert_includes labels, "x"
      end
    end
  end

  def test_completion_works_inside_if_block_without_condition
    Dir.mktmpdir("milk-tea-lsp-headerless-if-completion") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        struct Point:
            x: int

        function main() -> int:
            let p = Point(x = 1)
            if:
                return p.
            return 0
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
        assert messages.any? { |message| message.include?("expected expression") }

        dot_line = source.lines.index { |line| line.include?("return p.") }
        dot_char = source.lines.fetch(dot_line).chomp.length

        completion = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => dot_line, "character" => dot_char },
        })
        labels = completion.fetch("result").fetch("items").map { |item| item.fetch("label") }

        assert_includes labels, "x"
      end
    end
  end

  def test_completion_uses_match_binding_inside_invalid_match_arm
    Dir.mktmpdir("milk-tea-lsp-invalid-match-arm-completion") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        struct Point:
            x: int

        variant MaybePoint:
            some(value: Point)
            none

        function main(value: MaybePoint) -> int:
            match value:
                MaybePoint.some as payload
                    return payload.
                MaybePoint.none:
                    return 0
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
        assert messages.any? { |message| message.include?("expected ':' before block") }

        dot_line = source.lines.index { |line| line.include?("return payload.") }
        dot_char = source.lines.fetch(dot_line).chomp.length

        completion = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => dot_line, "character" => dot_char },
        })
        labels = completion.fetch("result").fetch("items").map { |item| item.fetch("label") }

        assert_includes labels, "value"
      end
    end
  end

  def test_completion_returns_function_names
    with_shared_server do |client|
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
      function_items = result["items"].select { |i| %w[add main].include?(i["label"]) }
      function_items.each { |item| assert_equal 3, item["kind"] }
    end
  end

  def test_completion_returns_locals_inside_function_body
    source = <<~MT
      function test_locals(arg: int) -> int:
          var local = 42
          var other = 0
          return other
    MT
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_completion_locals_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 3, "character" => 0 }
      })
      result = response.fetch("result")
      labels = result["items"].map { |i| i["label"] }
      assert_includes labels, "arg"
      assert_includes labels, "local"
      assert_includes labels, "other"
    end
  end

  def test_completion_returns_method_names_after_dot
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_method_completion_test.mt"
      # Open valid source so analysis succeeds and is cached as last-good.
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_METHODS }
      })
      # Simulate user editing to a mid-state with "p." on the last line (breaks sema,
      # but last-good facts are retained so method completions still work).
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

  def test_completion_returns_static_methods_for_imported_type_receiver
    Dir.mktmpdir("mt_lsp_imported_type_completion") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      File.write(File.join(std_dir, "foo.mt"), <<~MT)
        public struct Point:
            x: int
            y: int

        extending Point:
            public static function zero() -> int:
                return 0

            public function length() -> int:
                return this.x + this.y
      MT

      source = <<~MT
        import std.foo as foo

        public function main() -> int:
            return foo.Point.zero()
      MT
      source_path = File.join(dir, "main.mt")
      File.write(source_path, source)

      server = MilkTea::LSP::Server.new(protocol: RecordingProtocol.new)
      begin
        uri = path_to_uri(source_path)
        workspace = server.instance_variable_get(:@workspace)
        workspace.open_document(uri, source)

        partial_source = source.sub("return foo.Point.zero()", "return foo.Point.")
        workspace.open_document(uri, partial_source)

        dot_line = partial_source.lines.index { |line| line.include?("return foo.Point.") }
        dot_char = partial_source.lines[dot_line].chomp.length

        result = server.send(:handle_completion, {
          "textDocument" => { "uri" => uri },
          "position"     => { "line" => dot_line, "character" => dot_char }
        })

        items = result.fetch(:items)
        labels = items.map { |item| item[:label] }

        assert_includes labels, "zero"
        refute_includes labels, "length"
      ensure
        server&.send(:stop_diagnostics_workers)
      end
    end
  end

  def test_completion_returns_fields_and_methods_for_local_value_receiver
    with_shared_server do |client|
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
    with_shared_server do |client|
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
    with_shared_server do |client|
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
    with_shared_server do |client|
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
    with_shared_server do |client|
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
    with_shared_server do |client|
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

  def test_completion_uses_enclosing_receiver_for_this_in_editable_method
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_editable_this_completion_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_EDITABLE_METHOD_RECEIVER_COMPLETION }
      })

      partial_source = SOURCE_WITH_EDITABLE_METHOD_RECEIVER_COMPLETION.sub("        this.value = 0", "        this.")
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => partial_source }]
      })

      dot_line = partial_source.lines.index { |line| line.include?("this.") }
      dot_char = partial_source.lines[dot_line].chomp.length

      response = client.send_request("textDocument/completion", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => dot_line, "character" => dot_char }
      })

      labels = response.fetch("result").fetch("items").map { |i| i["label"] }
      assert_includes labels, "value"
      assert_includes labels, "reset"
    end
  end

end
