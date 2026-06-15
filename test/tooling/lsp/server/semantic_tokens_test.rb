# frozen_string_literal: true

require_relative "helpers"

class SemanticTokensTest < Minitest::Test
  include LSPServerTestHelpers

  def test_semantic_tokens_preserve_import_alias_classification_after_multi_range_did_change_batch
    Dir.mktmpdir("milk-tea-lsp-semantic-import-alias-batch") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      string_source = <<~MT
        public struct String:
            len: ptr_uint
      MT
      main_source = <<~MT
        import std.string as string

        function lookup_public_ip() -> Result[string.String, string.String]:
            let value = string.String.from_str("ok")
            return Result[string.String, string.String].success(value = value)
      MT

      File.write(File.join(std_dir, "string.mt"), string_source)
      main_path = File.join(dir, "main.mt")
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => main_uri, "languageId" => "milk-tea", "version" => 1, "text" => main_source }
        })

        # Simulate a rename-style multi-edit batch where all ranges are relative
        # to the same original snapshot and include multiple edits on one line.
        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => main_uri, "version" => 2 },
          "contentChanges" => [
            {
              "range" => {
                "start" => { "line" => 0, "character" => 21 },
                "end" => { "line" => 0, "character" => 27 },
              },
              "text" => "s"
            },
            {
              "range" => {
                "start" => { "line" => 2, "character" => 38 },
                "end" => { "line" => 2, "character" => 44 },
              },
              "text" => "s"
            },
            {
              "range" => {
                "start" => { "line" => 2, "character" => 53 },
                "end" => { "line" => 2, "character" => 59 },
              },
              "text" => "s"
            },
            {
              "range" => {
                "start" => { "line" => 3, "character" => 16 },
                "end" => { "line" => 3, "character" => 22 },
              },
              "text" => "s"
            },
            {
              "range" => {
                "start" => { "line" => 4, "character" => 16 },
                "end" => { "line" => 4, "character" => 22 },
              },
              "text" => "s"
            },
            {
              "range" => {
                "start" => { "line" => 4, "character" => 31 },
                "end" => { "line" => 4, "character" => 37 },
              },
              "text" => "s"
            },
          ]
        })

        semantic = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => main_uri }
        })

        data = semantic.dig("result", "data")
        refute_nil data

        # Decode semantic token stream to absolute ranges.
        line = 0
        char = 0
        entries = []
        index = 0
        while index < data.length
          delta_line = data[index]
          delta_char = data[index + 1]
          length = data[index + 2]
          token_type = data[index + 3]
          modifiers = data[index + 4]

          line += delta_line
          char = delta_line.zero? ? char + delta_char : delta_char
          entries << [line, char, length, token_type, modifiers]
          index += 5
        end

        # Assert both renamed aliases in `Result[s.String, s.String]` are namespaces.
        first_alias_col = "function lookup_public_ip() -> Result[s.String, s.String]:".index("s.String")
        second_alias_col = "function lookup_public_ip() -> Result[s.String, s.String]:".rindex("s.String")

        first_entry = entries.find { |entry| entry[0] == 2 && entry[1] == first_alias_col && entry[2] == 1 }
        second_entry = entries.find { |entry| entry[0] == 2 && entry[1] == second_alias_col && entry[2] == 1 }

        refute_nil first_entry, "expected semantic token entry for first renamed import alias `s`"
        refute_nil second_entry, "expected semantic token entry for second renamed import alias `s`"
        assert_equal 0, first_entry[3], "expected first renamed import alias to be namespace token type"
        assert_equal 0, second_entry[3], "expected second renamed import alias to be namespace token type"
      end
    end
  end

  def test_semantic_tokens_classify_import_heavy_imported_module_function_reference_as_function
    Dir.mktmpdir("lsp_semantic_import_heavy") do |dir|
      c_dir = File.join(dir, "std", "c")
      FileUtils.mkdir_p(c_dir)

      File.write(File.join(c_dir, "sdl3.mt"), <<~MT)
        external

        external function SDL_SetWindowFillDocument(window: ptr[void], fill: bool) -> bool
      MT

      %w[alpha beta gamma].each do |name|
        File.write(File.join(dir, "std", "#{name}.mt"), <<~MT)
          public function answer() -> int:
              return 42
        MT
      end

      source_path = File.join(dir, "std", "sdl3.mt")
      FileUtils.mkdir_p(File.dirname(source_path))
      source = <<~MT
        import std.c.sdl3 as c
        import std.alpha as a
        import std.beta as b
        import std.gamma as g

        public foreign function set_window_fill_document(window: ptr[void], fill: bool) -> bool = c.SDL_SetWindowFillDocument
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

  def test_semantic_tokens_locked_uses_package_lock_when_manifest_dependencies_drift
    Dir.mktmpdir("milk-tea-lsp-locked-semantic-tokens") do |dir|
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

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => main_uri }
        })

        legend = {
          "tokenTypes" => MilkTea::LSP::Server::SEMANTIC_TOKEN_TYPES,
          "tokenModifiers" => MilkTea::LSP::Server::SEMANTIC_TOKEN_MODIFIERS,
        }
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        alias_entry = semantic_entry_for_lexeme(main_source, entries, "duel_ui")
        member_entry = semantic_entry_for_lexeme(main_source, entries, "default_width")

        assert_equal "namespace", alias_entry.fetch("tokenType")
        assert_equal "function", member_entry.fetch("tokenType")
      end
    end
  end

  def test_semantic_tokens_classify_imported_module_function_reference_as_function
    Dir.mktmpdir("mt_lsp_semantic_tokens") do |dir|
      c_dir = File.join(dir, "std", "c")
      FileUtils.mkdir_p(c_dir)

      File.write(File.join(c_dir, "sdl3.mt"), <<~MT)
        external

        external function SDL_SetWindowFillDocument(window: ptr[void], fill: bool) -> bool
      MT

      source_path = File.join(dir, "std", "sdl3.mt")
      FileUtils.mkdir_p(File.dirname(source_path))
      source = <<~MT
        import std.c.sdl3 as c

        public foreign function set_window_fill_document(window: ptr[void], fill: bool) -> bool = c.SDL_SetWindowFillDocument
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

  def test_semantic_tokens_classify_imported_type_static_method_as_method
    Dir.mktmpdir("mt_lsp_semantic_tokens_static_method") do |dir|
      demo_dir = File.join(dir, "demo")
      FileUtils.mkdir_p(demo_dir)

      File.write(File.join(demo_dir, "dep.mt"), <<~MT)
        public struct Box[T]:
            value: T

        extending Box[T]:
            public static function create(value: T) -> Box[T]:
                return Box[T](value = value)
      MT

      source_path = File.join(dir, "main.mt")
      source = <<~MT
        import demo.dep as dep

        function main() -> dep.Box[int]:
            return dep.Box[int].create(1)
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

        create_entry = semantic_entry_for_lexeme(source, entries, "create")

        assert_equal "method", create_entry.fetch("tokenType")
      end
    end
  end

  def test_semantic_tokens_classify_loose_workspace_imported_module_function_reference_as_function
    Dir.mktmpdir("mt_lsp_semantic_tokens_loose_root") do |dir|
      demo_dir = File.join(dir, "demo")
      FileUtils.mkdir_p(demo_dir)

      File.write(File.join(demo_dir, "lib.mt"), <<~MT)
        public function greet() -> int:
            return 1
      MT

      source_path = File.join(dir, "main.mt")
      source = <<~MT
        import demo.lib as lib

        function main() -> int:
            return lib.greet()
      MT
      File.write(source_path, source)

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        uri = path_to_uri(source_path)
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        alias_entry = semantic_entry_for_lexeme(source, entries, "lib")
        member_entry = semantic_entry_for_lexeme(source, entries, "greet")

        assert_equal "namespace", alias_entry.fetch("tokenType")
        assert_equal "function", member_entry.fetch("tokenType")
      end
    end
  end

  def test_semantic_tokens_do_not_classify_invalid_imported_module_function_reference_as_function
    Dir.mktmpdir("mt_lsp_semantic_tokens_invalid_imported") do |dir|
      c_dir = File.join(dir, "std", "c")
      FileUtils.mkdir_p(c_dir)

      File.write(File.join(c_dir, "sdl3.mt"), <<~MT)
        external

        external function SDL_SetWindowFillDocument(window: ptr[void], fill: bool) -> bool
      MT

      source_path = File.join(dir, "std", "sdl3.mt")
      FileUtils.mkdir_p(File.dirname(source_path))
      source = <<~MT
        import std.c.sdl3 as c

        function main() -> int:
            let callback = c.SDL_SetWindowFillDocument
            return 0
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
        member_line = source.lines.index { |line| line.include?("SDL_SetWindowFillDocument") }
        member_entry = semantic_entry_for_lexeme_on_line(source, entries, "SDL_SetWindowFillDocument", member_line)

        assert_equal "property", member_entry.fetch("tokenType")
      end
    end
  end

  def test_semantic_tokens_classify_large_std_imported_module_type_reference
    Dir.mktmpdir("mt_lsp_semantic_tokens_large_std") do |dir|
      c_dir = File.join(dir, "std", "c")
      FileUtils.mkdir_p(c_dir)

      File.write(File.join(c_dir, "raylib.mt"), <<~MT)
        external

        struct Vector2:
            x: float
            y: float
      MT

      filler = (1..160).map { |i| "public const PAD_#{i}: int = #{i}" }.join("\n")
      source_path = File.join(dir, "std", "raylib.mt")
      FileUtils.mkdir_p(File.dirname(source_path))
      source = <<~MT
        import std.c.raylib as c

        public type VecAlias = c.Vector2
        #{filler}
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
        type_alias_line = source.lines.index { |line| line.include?("c.Vector2") }

        alias_entry = entries.find do |entry|
          next false unless entry.fetch("line") == type_alias_line

          line_text = source.lines.fetch(entry.fetch("line"))
          line_text[entry.fetch("startChar"), 1] == "c"
        end or flunk("expected semantic token entry for aliased module receiver on the type alias line")

        member_entry = entries.find do |entry|
          next false unless entry.fetch("line") == type_alias_line

          line_text = source.lines.fetch(entry.fetch("line"))
          line_text[entry.fetch("startChar"), "Vector2".length] == "Vector2"
        end or flunk("expected semantic token entry for imported type member on the type alias line")

        assert_equal "namespace", alias_entry.fetch("tokenType")
        assert_equal "type", member_entry.fetch("tokenType")
      end
    end
  end

  def test_semantic_tokens_keep_generic_helper_parameter_declarations_and_imported_lowercase_enum_members
    Dir.mktmpdir("mt_lsp_semantic_tokens_generic_helper_enum") do |dir|
      c_dir = File.join(dir, "std", "c")
      FileUtils.mkdir_p(c_dir)

      File.write(File.join(c_dir, "foo.mt"), <<~MT)
        external

        enum thing_t: int
            THING_A = 1
      MT

      source_path = File.join(dir, "demo.mt")
      source = <<~MT
        import std.c.foo as c

        function uses_helper(loop: int) -> int:
            return helper[int](loop)

        function helper[T](value: T) -> T:
            return value

        function use_enum() -> c.thing_t:
            return c.thing_t.THING_A
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
        loop_decl_line = source.lines.index { |line| line.include?("function uses_helper") }
        enum_member_line = source.lines.index { |line| line.include?("THING_A") }
        loop_decl = semantic_entry_for_lexeme_on_line(source, entries, "loop", loop_decl_line)
        enum_member = semantic_entry_for_lexeme_on_line(source, entries, "THING_A", enum_member_line)

        assert_equal "parameter", loop_decl.fetch("tokenType")
        assert_includes loop_decl.fetch("modifierNames"), "declaration"
        assert_equal "enumMember", enum_member.fetch("tokenType")
      end
    end
  end

  def test_semantic_tokens_refresh_after_imported_module_did_change
    Dir.mktmpdir("mt_lsp_semantic_tokens_import_change") do |dir|
      Dir.mkdir(File.join(dir, "std"))
      api_path = File.join(dir, "api.mt")
      main_path = File.join(dir, "main.mt")

      api_initial = <<~MT
      MT
      api_updated = <<~MT
        public type Answer = int
      MT
      main_source = <<~MT
        import api as api

        public type Reply = api.Answer
      MT

      File.write(api_path, api_initial)
      File.write(main_path, main_source)

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        api_uri = path_to_uri(api_path)
        main_uri = path_to_uri(main_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => api_uri, "languageId" => "milk-tea", "version" => 1, "text" => api_initial }
        })
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => main_uri, "languageId" => "milk-tea", "version" => 1, "text" => main_source }
        })

        first = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => main_uri }
        })
        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        first_entries = decode_semantic_token_entries(first.fetch("result").fetch("data"), legend)
        first_answer = semantic_entry_for_lexeme(main_source, first_entries, "Answer")

        assert_equal "property", first_answer.fetch("tokenType")

        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => api_uri, "version" => 2 },
          "contentChanges" => [{ "text" => api_updated }]
        })

        second = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => main_uri }
        })
        second_entries = decode_semantic_token_entries(second.fetch("result").fetch("data"), legend)
        second_answer = semantic_entry_for_lexeme(main_source, second_entries, "Answer")

        assert_equal "type", second_answer.fetch("tokenType")
      end
    end
  end

  def test_semantic_tokens_do_not_refresh_after_non_export_imported_module_edit
    Dir.mktmpdir("mt_lsp_semantic_tokens_import_no_surface_change") do |dir|
      Dir.mkdir(File.join(dir, "std"))
      api_path = File.join(dir, "api.mt")
      main_path = File.join(dir, "main.mt")

      api_initial = <<~MT
        public function answer() -> int:
            return 1
      MT
      api_updated = <<~MT
        public function answer() -> int:
            return 2
      MT
      main_source = <<~MT
        import api as api

        function main() -> int:
            return api.answer()
      MT

      File.write(api_path, api_initial)
      File.write(main_path, main_source)

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        api_uri = path_to_uri(api_path)
        main_uri = path_to_uri(main_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => api_uri, "languageId" => "milk-tea", "version" => 1, "text" => api_initial }
        })
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => main_uri, "languageId" => "milk-tea", "version" => 1, "text" => main_source }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        first = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => main_uri }
        })
        first_entries = decode_semantic_token_entries(first.fetch("result").fetch("data"), legend)
        first_answer = semantic_entry_for_lexeme(main_source, first_entries, "answer")
        first_type = first_answer.fetch("tokenType")

        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => api_uri, "version" => 2 },
          "contentChanges" => [{ "text" => api_updated }]
        })

        second = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => main_uri }
        })
        second_entries = decode_semantic_token_entries(second.fetch("result").fetch("data"), legend)
        second_answer = semantic_entry_for_lexeme(main_source, second_entries, "answer")

        assert_equal first_type, second_answer.fetch("tokenType")
      end
    end
  end

  def test_semantic_tokens_classify_local_interfaces_like_types
    source = <<~MT
      interface ScreenState:
          function draw(texture: int) -> void

      struct PauseScreen implements ScreenState:
          ticks: int

      extending PauseScreen:
          function draw(texture: int) -> void:
              let sink = texture

      function run_screen_frame[T implements ScreenState](screen: ref[T], texture: int) -> void:
          screen.draw(texture)
    MT

    with_server do |client|
      init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_semantic_interface_local_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/semanticTokens/full", {
        "textDocument" => { "uri" => uri }
      })

      legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
      entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

      interface_decl = semantic_entry_for_lexeme_on_line(source, entries, "ScreenState", 0)
      interface_impl = semantic_entry_for_lexeme_on_line(source, entries, "ScreenState", 3)
      interface_constraint = semantic_entry_for_lexeme_on_line(source, entries, "ScreenState", 10)

      assert_equal "type", interface_decl.fetch("tokenType")
      assert_includes interface_decl.fetch("modifierNames"), "declaration"
      assert_equal "type", interface_impl.fetch("tokenType")
      assert_equal "type", interface_constraint.fetch("tokenType")
    end
  end

  def test_semantic_tokens_classify_imported_interfaces_like_types
    Dir.mktmpdir("mt_lsp_semantic_tokens_imported_interface") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      contracts_source = <<~MT
        public interface Damageable:
            editable function take_damage(amount: int) -> void
      MT
      main_source = <<~MT
        import std.contracts as contracts

        struct NPC implements contracts.Damageable:
            hp: int

        extending NPC:
            editable function take_damage(amount: int):
                this.hp -= amount
      MT

      contracts_path = File.join(std_dir, "contracts.mt")
      main_path = File.join(dir, "main.mt")
      File.write(contracts_path, contracts_source)
      File.write(main_path, main_source)

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        uri = path_to_uri(main_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => main_source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        implements_line = main_source.lines.index { |line| line.include?("contracts.Damageable") }
        alias_entry = semantic_entry_for_lexeme_on_line(main_source, entries, "contracts", implements_line)
        interface_entry = semantic_entry_for_lexeme_on_line(main_source, entries, "Damageable", implements_line)

        assert_equal "namespace", alias_entry.fetch("tokenType")
        assert_equal "type", interface_entry.fetch("tokenType")
      end
    end
  end

  def test_semantic_tokens_classify_event_declarations
    source = <<~MT
      event reloaded[4]

      struct Window:
          public event closed[4]
          title: str

      function main() -> void:
          reloaded.emit()
    MT

    with_server do |client|
      init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_semantic_event_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/semanticTokens/full", {
        "textDocument" => { "uri" => uri }
      })

      legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
      entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

      top_level_event = semantic_entry_for_lexeme_on_line(source, entries, "reloaded", 0)
      struct_event = semantic_entry_for_lexeme_on_line(source, entries, "closed", 3)

      assert_equal "variable", top_level_event.fetch("tokenType")
      assert_includes top_level_event.fetch("modifierNames"), "declaration"
      assert_equal "property", struct_event.fetch("tokenType")
      assert_includes struct_event.fetch("modifierNames"), "declaration"
    end
  end


    def test_semantic_tokens_classify_str_buffer_and_value_receiver_methods
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_str_buffer_test.mt"
        source = SOURCE_WITH_STR_BUFFER_METHODS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        str_buffer_entry = semantic_entry_for_lexeme(source, entries, "str_buffer")
        assign_entry = semantic_entry_for_lexeme(source, entries, "assign")
        as_str_entry = semantic_entry_for_lexeme(source, entries, "as_str")
        capacity_entry = semantic_entry_for_lexeme(source, entries, "capacity")

        assert_equal "type", str_buffer_entry.fetch("tokenType")
        assert_equal "method", assign_entry.fetch("tokenType")
        assert_equal "method", as_str_entry.fetch("tokenType")
        assert_equal "method", capacity_entry.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_array_and_span_as_types_but_array_ctor_as_function
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_generic_types_test.mt"
        source = SOURCE_WITH_GENERIC_TYPE_SURFACES
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        span_type_entry = entries.find do |entry|
          entry.fetch("line") == 0 && source.lines.fetch(entry.fetch("line"))[entry.fetch("startChar"), 4] == "span"
        end or flunk("expected span semantic token entry in parameter type")

        array_return_entry = entries.find do |entry|
          entry.fetch("line") == 0 && source.lines.fetch(entry.fetch("line"))[entry.fetch("startChar"), 5] == "array"
        end or flunk("expected array semantic token entry in return type")

        array_ctor_entry = entries.find do |entry|
          entry.fetch("line") == 1 && source.lines.fetch(entry.fetch("line"))[entry.fetch("startChar"), 5] == "array"
        end or flunk("expected array semantic token entry in constructor call")

        assert_equal "type", span_type_entry.fetch("tokenType")
        assert_equal "type", array_return_entry.fetch("tokenType")
        assert_equal "function", array_ctor_entry.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_all_generic_type_arguments_as_type_parameters
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_multi_type_argument_test.mt"
        source = SOURCE_WITH_MULTI_TYPE_ARGUMENT_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        field_k = semantic_entry_for_lexeme_on_line(source, entries, "K", 4)
        field_v = semantic_entry_for_lexeme_on_line(source, entries, "V", 4)
        ctor_k = semantic_entry_for_lexeme_on_line(source, entries, "K", 7)
        ctor_v = semantic_entry_for_lexeme_on_line(source, entries, "V", 7)

        assert_equal "typeParameter", field_k.fetch("tokenType")
        assert_equal "typeParameter", field_v.fetch("tokenType")
        assert_equal "typeParameter", ctor_k.fetch("tokenType")
        assert_equal "typeParameter", ctor_v.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_generic_methods_receiver_and_receiver_type_parameters
      source = <<~MT
        struct Cache[K, V]:
            key: K
            value: V

        extending Cache[K, V]:
            function read_key() -> K:
                return this.key

            function read_value() -> V:
                return this.value

            function choose[T](fallback: T) -> T:
                let selected = fallback
                return selected

            static function create(key: K, value: V) -> Cache[K, V]:
                return Cache[K, V](key = key, value = value)
      MT

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_generic_methods_receiver_test.mt"
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        header_k = semantic_entry_for_lexeme_on_line(source, entries, "K", 4)
        header_v = semantic_entry_for_lexeme_on_line(source, entries, "V", 4)
        read_key_return = semantic_entry_for_lexeme_on_line(source, entries, "K", 5)
        read_value_return = semantic_entry_for_lexeme_on_line(source, entries, "V", 8)
        this_key = semantic_entry_for_lexeme_on_line(source, entries, "this", 6)
        this_value = semantic_entry_for_lexeme_on_line(source, entries, "this", 9)
        fallback_ref = semantic_entry_for_lexeme_on_line(source, entries, "fallback", 12)
        selected_decl = semantic_entry_for_lexeme_on_line(source, entries, "selected", 12)
        selected_ref = semantic_entry_for_lexeme_on_line(source, entries, "selected", 13)
        ctor_k = semantic_entry_for_lexeme_on_line(source, entries, "K", 16)
        ctor_v = semantic_entry_for_lexeme_on_line(source, entries, "V", 16)

        assert_equal "typeParameter", header_k.fetch("tokenType")
        assert_includes header_k.fetch("modifierNames"), "declaration"
        assert_equal "typeParameter", header_v.fetch("tokenType")
        assert_includes header_v.fetch("modifierNames"), "declaration"
        assert_equal "typeParameter", read_key_return.fetch("tokenType")
        assert_equal "typeParameter", read_value_return.fetch("tokenType")
        assert_equal "parameter", this_key.fetch("tokenType")
        assert_equal "parameter", this_value.fetch("tokenType")
        assert_equal "parameter", fallback_ref.fetch("tokenType")
        assert_equal "variable", selected_decl.fetch("tokenType")
        assert_includes selected_decl.fetch("modifierNames"), "declaration"
        assert_equal "variable", selected_ref.fetch("tokenType")
        assert_equal "typeParameter", ctor_k.fetch("tokenType")
        assert_equal "typeParameter", ctor_v.fetch("tokenType")
      end
    end

    def test_semantic_tokens_prefer_parameter_binding_over_builtin_type_name
      source = <<~MT
        function is_ascii_space(ch: ubyte) -> bool:
            return ch == 32
      MT

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_byte_parameter_test.mt"
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        byte_decl = semantic_entry_for_lexeme_on_line(source, entries, "ch", 0)
        byte_ref = semantic_entry_for_lexeme_on_line(source, entries, "ch", 1)

        assert_equal "parameter", byte_decl.fetch("tokenType")
        assert_includes byte_decl.fetch("modifierNames"), "declaration"
        assert_equal "parameter", byte_ref.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_ordered_map_receiver_type_parameters_and_members
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
        source_path = File.join(Dir.pwd, "std", "ordered_map.mt")
        source = File.read(source_path)
        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        header_line = source.lines.index { |line| line == "extending OrderedMap[K, V]:\n" } or flunk("expected OrderedMap extending header")
        set_line = source.lines.index { |line| line.include?("public editable function set(key: K, value: V) -> Option[V]:") } or flunk("expected OrderedMap.set declaration")
        entries_line = source.lines.index { |line| line.include?("return this.entries()") } or flunk("expected OrderedMap.iter body")
        next_line = source.lines.index { |line| line.include?("if not this.started:") } or flunk("expected Entries.next guard")
        current_line = source.lines.index { |line| line.include?("public function current() -> Entry[K, V]:") } or flunk("expected Entries.current declaration")
        current_guard_line = source.lines.index { |line| line.include?("if current == null or not this.started:") } or flunk("expected Entries.current guard")

        header_k = semantic_entry_for_lexeme_on_line(source, entries, "K", header_line)
        header_v = semantic_entry_for_lexeme_on_line(source, entries, "V", header_line)
        option_type = semantic_entry_for_lexeme_on_line(source, entries, "Option", set_line)
        entries_call = semantic_entry_for_lexeme_on_line(source, entries, "entries", entries_line)
        next_this = semantic_entry_for_lexeme_on_line(source, entries, "this", next_line)
        next_started = semantic_entry_for_lexeme_on_line(source, entries, "started", next_line)
        current_decl = semantic_entry_for_lexeme_on_line(source, entries, "current", current_line)
        entry_return = semantic_entry_for_lexeme_on_line(source, entries, "Entry", current_line)
        current_k = semantic_entry_for_lexeme_on_line(source, entries, "K", current_line)
        current_v = semantic_entry_for_lexeme_on_line(source, entries, "V", current_line)
        current_this = semantic_entry_for_lexeme_on_line(source, entries, "this", current_guard_line)
        current_started = semantic_entry_for_lexeme_on_line(source, entries, "started", current_guard_line)

        assert_equal "typeParameter", header_k.fetch("tokenType")
        assert_includes header_k.fetch("modifierNames"), "declaration"
        assert_equal "typeParameter", header_v.fetch("tokenType")
        assert_includes header_v.fetch("modifierNames"), "declaration"
        assert_equal "type", option_type.fetch("tokenType")
        assert_equal "method", entries_call.fetch("tokenType")
        assert_equal "parameter", next_this.fetch("tokenType")
        assert_equal "property", next_started.fetch("tokenType")
        assert_equal "function", current_decl.fetch("tokenType")
        assert_equal "type", entry_return.fetch("tokenType")
        assert_equal "typeParameter", current_k.fetch("tokenType")
        assert_equal "typeParameter", current_v.fetch("tokenType")
        assert_equal "parameter", current_this.fetch("tokenType")
        assert_equal "property", current_started.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_binary_heap_receiver_type_parameter_and_members
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
        source_path = File.join(Dir.pwd, "std", "binary_heap.mt")
        source = File.read(source_path)
        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        header_line = source.lines.index { |line| line == "extending BinaryHeap[T]:\n" } or flunk("expected BinaryHeap extending header")
        create_line = source.lines.index { |line| line.include?("return BinaryHeap[T](values = vec.Vec[T].create())") } or flunk("expected BinaryHeap.create body")
        push_line = source.lines.index { |line| line.include?("this.values.push(value)") } or flunk("expected BinaryHeap.push body")

        header_t = semantic_entry_for_lexeme_on_line(source, entries, "T", header_line)
        vec_alias = semantic_entry_for_lexeme_on_line(source, entries, "vec", create_line)
        push_this = semantic_entry_for_lexeme_on_line(source, entries, "this", push_line)
        push_values = semantic_entry_for_lexeme_on_line(source, entries, "values", push_line)
        push_call = semantic_entry_for_lexeme_on_line(source, entries, "push", push_line)

        assert_equal "typeParameter", header_t.fetch("tokenType")
        assert_includes header_t.fetch("modifierNames"), "declaration"
        assert_equal "namespace", vec_alias.fetch("tokenType")
        assert_equal "parameter", push_this.fetch("tokenType")
        assert_equal "property", push_values.fetch("tokenType")
        assert_equal "method", push_call.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_priority_queue_receiver_type_parameter_and_members
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
        source_path = File.join(Dir.pwd, "std", "priority_queue.mt")
        source = File.read(source_path)
        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        header_line = source.lines.index { |line| line == "extending PriorityQueue[T]:\n" } or flunk("expected PriorityQueue extending header")
        iter_signature_line = source.lines.index { |line| line.include?("public function iter() -> binary_heap.Iter[T]:") } or flunk("expected PriorityQueue.iter signature")
        iter_line = source.lines.index { |line| line.include?("return this.values.iter()") } or flunk("expected PriorityQueue.iter body")
        enqueue_line = source.lines.index { |line| line.include?("this.values.push(value)") } or flunk("expected PriorityQueue.enqueue body")
        dequeue_line = source.lines.index { |line| line.include?("return this.values.pop()") } or flunk("expected PriorityQueue.dequeue body")

        header_t = semantic_entry_for_lexeme_on_line(source, entries, "T", header_line)
        binary_heap_alias = semantic_entry_for_lexeme_on_line(source, entries, "binary_heap", iter_signature_line)
        iter_this = semantic_entry_for_lexeme_on_line(source, entries, "this", iter_line)
        iter_values = semantic_entry_for_lexeme_on_line(source, entries, "values", iter_line)
        iter_call = semantic_entry_for_lexeme_on_line(source, entries, "iter", iter_line)
        enqueue_push = semantic_entry_for_lexeme_on_line(source, entries, "push", enqueue_line)
        dequeue_pop = semantic_entry_for_lexeme_on_line(source, entries, "pop", dequeue_line)

        assert_equal "typeParameter", header_t.fetch("tokenType")
        assert_includes header_t.fetch("modifierNames"), "declaration"
        assert_equal "namespace", binary_heap_alias.fetch("tokenType")
        assert_equal "parameter", iter_this.fetch("tokenType")
        assert_equal "property", iter_values.fetch("tokenType")
        assert_equal "method", iter_call.fetch("tokenType")
        assert_equal "method", enqueue_push.fetch("tokenType")
        assert_equal "method", dequeue_pop.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_ordered_set_receiver_type_parameter_and_members
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
        source_path = File.join(Dir.pwd, "std", "ordered_set.mt")
        source = File.read(source_path)
        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        header_line = source.lines.index { |line| line == "extending OrderedSet[T]:\n" } or flunk("expected OrderedSet extending header")
        contains_line = source.lines.index { |line| line.include?("return this.get(value) != null") } or flunk("expected OrderedSet.contains body")
        iter_line = source.lines.index { |line| line.include?("return Iter[T](node = OrderedSet[T].minimum(this.root))") } or flunk("expected OrderedSet.iter body")
        next_line = source.lines.index { |line| line.include?("this.node = OrderedSet[T].successor(current)") } or flunk("expected OrderedSet.Iter.next body")

        header_t = semantic_entry_for_lexeme_on_line(source, entries, "T", header_line)
        contains_this = semantic_entry_for_lexeme_on_line(source, entries, "this", contains_line)
        get_call = semantic_entry_for_lexeme_on_line(source, entries, "get", contains_line)
        iter_t = semantic_entry_for_lexeme_on_line(source, entries, "T", iter_line)
        iter_root = semantic_entry_for_lexeme_on_line(source, entries, "root", iter_line)
        next_this = semantic_entry_for_lexeme_on_line(source, entries, "this", next_line)
        next_node = semantic_entry_for_lexeme_on_line(source, entries, "node", next_line)

        assert_equal "typeParameter", header_t.fetch("tokenType")
        assert_includes header_t.fetch("modifierNames"), "declaration"
        assert_equal "parameter", contains_this.fetch("tokenType")
        assert_equal "method", get_call.fetch("tokenType")
        assert_equal "typeParameter", iter_t.fetch("tokenType")
        assert_equal "property", iter_root.fetch("tokenType")
        assert_equal "parameter", next_this.fetch("tokenType")
        assert_equal "property", next_node.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_parameters_named_labels_and_for_binders
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_parameter_labels_test.mt"
        source = SOURCE_WITH_PARAMETER_AND_LABEL_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        position_decl = semantic_entry_for_lexeme_on_line(source, entries, "position", 4)
        position_ref = semantic_entry_for_lexeme_on_line(source, entries, "position", 7)
        x_label = semantic_entry_for_lexeme_on_line(source, entries, "x", 5)
        y_label = semantic_entry_for_lexeme_on_line(source, entries, "y", 5)
        index_decl = semantic_entry_for_lexeme_on_line(source, entries, "index", 6)
        index_ref = semantic_entry_for_lexeme_on_line(source, entries, "index", 7)

        assert_equal "parameter", position_decl.fetch("tokenType")
        assert_includes position_decl.fetch("modifierNames"), "declaration"
        assert_equal "parameter", position_ref.fetch("tokenType")
        refute_includes position_ref.fetch("modifierNames"), "declaration"
        assert_equal "property", x_label.fetch("tokenType")
        assert_equal "property", y_label.fetch("tokenType")
        assert_equal "variable", index_decl.fetch("tokenType")
        assert_includes index_decl.fetch("modifierNames"), "declaration"
        assert_equal "variable", index_ref.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_struct_field_declarations_and_member_access
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_struct_field_test.mt"
        source = SOURCE_WITH_STRUCT_FIELD_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        str_decl = semantic_entry_for_lexeme_on_line(source, entries, "str", 1)
        size_decl = semantic_entry_for_lexeme_on_line(source, entries, "size", 2)
        str_access = semantic_entry_for_lexeme_on_line(source, entries, "str", 5)
        size_access = semantic_entry_for_lexeme_on_line(source, entries, "size", 6)

        assert_equal "property", str_decl.fetch("tokenType")
        assert_includes str_decl.fetch("modifierNames"), "declaration"
        assert_equal "property", size_decl.fetch("tokenType")
        assert_includes size_decl.fetch("modifierNames"), "declaration"
        assert_equal "property", str_access.fetch("tokenType")
        refute_includes str_access.fetch("modifierNames"), "declaration"
        assert_equal "property", size_access.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_resolved_callables_for_constructors_and_callable_values
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_resolved_callable_test.mt"
        source = SOURCE_WITH_RESOLVED_CALLABLE_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        point_ctor = semantic_entry_for_lexeme_on_line(source, entries, "Point", 11)
        entry_ctor = semantic_entry_for_lexeme_on_line(source, entries, "Entry", 16)
        callback_call = semantic_entry_for_lexeme_on_line(source, entries, "callback", 17)
        field_callback_call = semantic_entry_for_lexeme_on_line(source, entries, "callback", 18)
        add_call = semantic_entry_for_lexeme_on_line(source, entries, "add", 19)

        assert_equal "type", point_ctor.fetch("tokenType")
        assert_equal "type", entry_ctor.fetch("tokenType")
        assert_equal "variable", callback_call.fetch("tokenType")
        assert_equal "property", field_callback_call.fetch("tokenType")
        assert_equal "function", add_call.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_function_values_and_bare_zero_specialization
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_function_value_zero_test.mt"
        source = SOURCE_WITH_FUNCTION_VALUE_AND_ZERO_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        callback_value_line = source.lines.index { |text| text.include?("let callback: fn(value: int) -> int = add_one") }
        zero_value_line = source.lines.index { |text| text.include?("let zeroed = zero[Box]") }
        default_value_line = source.lines.index { |text| text.include?("let defaulted = default[Box]") }
        callback_argument_line = source.lines.index { |text| text.include?("return apply(add_one, zeroed.value) + callback(defaulted.value)") }

        callback_value = semantic_entry_for_lexeme_on_line(source, entries, "add_one", callback_value_line)
        zero_value = semantic_entry_for_lexeme_on_line(source, entries, "zero", zero_value_line)
        default_value = semantic_entry_for_lexeme_on_line(source, entries, "default", default_value_line)
        callback_argument = semantic_entry_for_lexeme_on_line(source, entries, "add_one", callback_argument_line)

        assert_equal "function", callback_value.fetch("tokenType")
        assert_equal "function", callback_argument.fetch("tokenType")
        assert_equal "function", zero_value.fetch("tokenType")
        assert_equal "function", default_value.fetch("tokenType")
        assert_includes zero_value.fetch("modifierNames"), "defaultLibrary"
        assert_includes default_value.fetch("modifierNames"), "defaultLibrary"
      end
    end

    def test_semantic_tokens_do_not_mark_user_defined_cast_or_range_as_default_library
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_user_defined_cast_range_test.mt"
        source = SOURCE_WITH_USER_DEFINED_CAST_AND_RANGE_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        cast_call = semantic_entry_for_lexeme_on_line(source, entries, "cast", 7)
        range_call = semantic_entry_for_lexeme_on_line(source, entries, "range", 8)

        assert_equal "function", cast_call.fetch("tokenType")
        assert_equal "function", range_call.fetch("tokenType")
        refute_includes cast_call.fetch("modifierNames"), "defaultLibrary"
        refute_includes range_call.fetch("modifierNames"), "defaultLibrary"
      end
    end

    def test_semantic_tokens_treat_cast_expression_parameter_references_like_other_parameter_references
      source = <<~MT
        function encode_u32(value: uint) -> array[ubyte, 4]:
            return array[ubyte, 4](
                ubyte<-((value >> 24) & 255),
                ubyte<-((value >> 16) & 255),
                ubyte<-((value >> 8) & 255),
                ubyte<-(value & 255)
            )
      MT

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_cast_expression_parameter_test.mt"
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        declaration = semantic_entry_for_lexeme_on_line(source, entries, "value", 0)
        first_reference = semantic_entry_for_lexeme_on_line(source, entries, "value", 2)
        second_reference = semantic_entry_for_lexeme_on_line(source, entries, "value", 3)
        third_reference = semantic_entry_for_lexeme_on_line(source, entries, "value", 4)
        final_reference = semantic_entry_for_lexeme_on_line(source, entries, "value", 5)

        assert_equal "parameter", declaration.fetch("tokenType")
        assert_includes declaration.fetch("modifierNames"), "declaration"
        [first_reference, second_reference, third_reference, final_reference].each do |reference|
          assert_equal "parameter", reference.fetch("tokenType")
          refute_includes reference.fetch("modifierNames"), "declaration"
        end
      end
    end

    def test_semantic_tokens_mark_builtin_associated_hooks_as_default_library
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_builtin_associated_hooks_test.mt"
        source = SOURCE_WITH_ASSOCIATED_HOOK_BUILTINS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        hash_line = source.lines.index { |text| text.include?("let hashed = hash[Key](key)") }
        equal_line = source.lines.index { |text| text.include?("let same = equal[Key](key, other)") }
        order_line = source.lines.index { |text| text.include?("order[Key](key, other)") }

        hash_call = semantic_entry_for_lexeme_on_line(source, entries, "hash", hash_line)
        equal_call = semantic_entry_for_lexeme_on_line(source, entries, "equal", equal_line)
        order_call = semantic_entry_for_lexeme_on_line(source, entries, "order", order_line)

        assert_equal "function", hash_call.fetch("tokenType")
        assert_equal "function", equal_call.fetch("tokenType")
        assert_equal "function", order_call.fetch("tokenType")
        assert_includes hash_call.fetch("modifierNames"), "defaultLibrary"
        assert_includes equal_call.fetch("modifierNames"), "defaultLibrary"
        assert_includes order_call.fetch("modifierNames"), "defaultLibrary"
      end
    end

    def test_semantic_tokens_mark_attribute_reflection_builtins_as_default_library
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_attribute_reflection_test.mt"
        source = <<~MT
          public attribute[field, callable] trace(name: str)

          @[packed]
          @[align(16)]
          struct Packet:
              @[trace("payload_len")]
              payload_len: uint

          @[trace("parse_packet")]
          function parse_packet() -> int:
              return 0

          static_assert(has_attribute(field_of(Packet, payload_len), trace), "field attribute missing")
          static_assert(has_attribute(callable_of(parse_packet), trace), "callable attribute missing")
          static_assert(
              has_attribute(Packet, packed) and
              attribute_arg[ptr_uint](attribute_of(Packet, align), bytes) == 16 and
              attribute_arg[str](attribute_of(field_of(Packet, payload_len), trace), name) == "payload_len",
              "attribute reflection changed"
          )

          function main() -> int:
              return 0
        MT

        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        has_attribute_field_line = source.lines.index { |text| text.include?("has_attribute(field_of(Packet, payload_len), trace)") }
        has_attribute_callable_line = source.lines.index { |text| text.include?("has_attribute(callable_of(parse_packet), trace)") }
        packed_attribute_line = source.lines.index { |text| text.include?("@[packed]") }
        align_attribute_line = source.lines.index { |text| text.include?("@[align(16)]") }
        trace_attribute_line = source.lines.index { |text| text.include?("@[trace(\"payload_len\")]") }
        packed_reflection_line = source.lines.index { |text| text.include?("has_attribute(Packet, packed) and") }
        align_reflection_line = source.lines.index { |text| text.include?("attribute_arg[ptr_uint](attribute_of(Packet, align), bytes) == 16") }
        attribute_arg_line = source.lines.index { |text| text.include?("attribute_arg[str](attribute_of(field_of(Packet, payload_len), trace), name)") }

        attribute_keyword = semantic_entry_for_lexeme_on_line(source, entries, "attribute", 0)
        attribute_decl_name = semantic_entry_for_lexeme_on_line(source, entries, "trace", 0)
        packed_attribute = semantic_entry_for_lexeme_on_line(source, entries, "packed", packed_attribute_line)
        align_attribute = semantic_entry_for_lexeme_on_line(source, entries, "align", align_attribute_line)
        trace_attribute = semantic_entry_for_lexeme_on_line(source, entries, "trace", trace_attribute_line)
        has_attribute_call = semantic_entry_for_lexeme_on_line(source, entries, "has_attribute", has_attribute_field_line)
        field_of_call = semantic_entry_for_lexeme_on_line(source, entries, "field_of", has_attribute_field_line)
        callable_of_call = semantic_entry_for_lexeme_on_line(source, entries, "callable_of", has_attribute_callable_line)
        attribute_arg_call = semantic_entry_for_lexeme_on_line(source, entries, "attribute_arg", attribute_arg_line)
        attribute_of_call = semantic_entry_for_lexeme_on_line(source, entries, "attribute_of", attribute_arg_line)
        trace_reflection_name = semantic_entry_for_lexeme_on_line(source, entries, "trace", has_attribute_field_line)
        packed_reflection_name = semantic_entry_for_lexeme_on_line(source, entries, "packed", packed_reflection_line)
        align_reflection_name = semantic_entry_for_lexeme_on_line(source, entries, "align", align_reflection_line)

        assert_equal "keyword", attribute_keyword.fetch("tokenType")
        assert_equal "decorator", attribute_decl_name.fetch("tokenType")
        assert_includes attribute_decl_name.fetch("modifierNames"), "declaration"

        [packed_attribute, align_attribute, trace_attribute, trace_reflection_name, packed_reflection_name, align_reflection_name].each do |entry|
          assert_equal "decorator", entry.fetch("tokenType")
          assert_empty entry.fetch("modifierNames")
        end

        [has_attribute_call, field_of_call, callable_of_call, attribute_arg_call, attribute_of_call].each do |entry|
          assert_equal "keyword", entry.fetch("tokenType")
          assert_empty entry.fetch("modifierNames")
        end
      end
    end

    def test_semantic_tokens_do_not_mark_user_defined_hash_equal_order_as_default_library
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_user_defined_associated_hooks_test.mt"
        source = SOURCE_WITH_USER_DEFINED_ASSOCIATED_HOOK_NAMES
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        hash_line = source.lines.index { |text| text.include?("let hashed = hash[int](value)") }
        equal_line = source.lines.index { |text| text.include?("let same = equal[int](value, value)") }
        order_line = source.lines.index { |text| text.include?("return order[int](value, value)") }

        hash_call = semantic_entry_for_lexeme_on_line(source, entries, "hash", hash_line)
        equal_call = semantic_entry_for_lexeme_on_line(source, entries, "equal", equal_line)
        order_call = semantic_entry_for_lexeme_on_line(source, entries, "order", order_line)

        assert_equal "function", hash_call.fetch("tokenType")
        assert_equal "function", equal_call.fetch("tokenType")
        assert_equal "function", order_call.fetch("tokenType")
        refute_includes hash_call.fetch("modifierNames"), "defaultLibrary"
        refute_includes equal_call.fetch("modifierNames"), "defaultLibrary"
        refute_includes order_call.fetch("modifierNames"), "defaultLibrary"
      end
    end

    def test_semantic_tokens_do_not_classify_invalid_bare_function_reference_as_function
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_invalid_bare_function_reference_test.mt"
        source = SOURCE_WITH_INVALID_BARE_FUNCTION_REFERENCE_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        invalid_reference = semantic_entry_for_lexeme_on_line(source, entries, "add_one", 4)

        assert_equal "variable", invalid_reference.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_specialized_member_calls_as_function_and_method
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
        source = SOURCE_WITH_SPECIALIZED_MEMBER_CALL_SEMANTICS
        path = File.join(Dir.pwd, "tmp", "lsp_semantic_specialized_member_calls_test.mt")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        create_for_line = source.lines.index { |line| line.include?("create_for") }
        alloc_line = source.lines.index { |line| line.include?("alloc") }
        create_for_entry = semantic_entry_for_lexeme_on_line(source, entries, "create_for", create_for_line)
        alloc_entry = semantic_entry_for_lexeme_on_line(source, entries, "alloc", alloc_line)

        assert_equal "function", create_for_entry.fetch("tokenType")
        assert_equal "method", alloc_entry.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_generic_parameter_shadowing_import_alias_as_parameter
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
        source = SOURCE_WITH_GENERIC_PARAMETER_SHADOWING_IMPORT_SEMANTICS
        path = File.join(Dir.pwd, "tmp", "lsp_semantic_generic_param_shadow_test.mt")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        status_decl_line = source.lines.index { |line| line.include?("function wrap") }
        status_if_line = source.lines.index { |line| line.include?("if status") }
        status_return_line = source.lines.index { |line| line.include?("return status") }
        status_decl = semantic_entry_for_lexeme_on_line(source, entries, "status", status_decl_line)
        status_if_ref = semantic_entry_for_lexeme_on_line(source, entries, "status", status_if_line)
        status_return_ref = semantic_entry_for_lexeme_on_line(source, entries, "status", status_return_line)

        assert_equal "parameter", status_decl.fetch("tokenType")
        assert_includes status_decl.fetch("modifierNames"), "declaration"
        assert_equal "parameter", status_if_ref.fetch("tokenType")
        refute_includes status_if_ref.fetch("modifierNames"), "declaration"
        assert_equal "parameter", status_return_ref.fetch("tokenType")
        refute_includes status_return_ref.fetch("modifierNames"), "declaration"
      end
    end

    def test_semantic_tokens_classify_specialized_generic_function_calls_as_function
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_specialized_function_call_test.mt"
        source = SOURCE_WITH_SPECIALIZED_FUNCTION_CALL_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        identity_call = semantic_entry_for_lexeme_on_line(source, entries, "identity", 4)

        assert_equal "function", identity_call.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_keyword_module_and_import_path_segments_as_namespace
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
        source = SOURCE_WITH_KEYWORD_NAMESPACE_PATH_SEMANTICS
        path = File.join(Dir.pwd, "tmp", "lsp_semantic_keyword_namespace_path_test.mt")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        import_async_line = source.lines.index { |line| line.include?("tmp.async") }
        import_async = semantic_entry_for_lexeme_on_line(source, entries, "async", import_async_line)

        assert_equal "namespace", import_async.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_generic_local_shadowing_and_specialized_function_values
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
        source = SOURCE_WITH_GENERIC_LOCAL_AND_SPECIALIZED_FUNCTION_VALUE_SEMANTICS
        path = File.join(Dir.pwd, "tmp", "lsp_semantic_generic_local_specialized_test.mt")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source)
        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        status_decl_line = source.lines.index { |line| line.include?("var status") }
        status_assign_line = source.lines.index { |line| line.include?("status = invoke") }
        status_if_line = source.lines.index { |line| line.include?("if status") }
        status_return_line = source.lines.index { |line| line.include?("return status") }
        status_decl = semantic_entry_for_lexeme_on_line(source, entries, "status", status_decl_line)
        status_assign_ref = semantic_entry_for_lexeme_on_line(source, entries, "status", status_assign_line)
        make_status_ref = semantic_entry_for_lexeme_on_line(source, entries, "make_status", status_assign_line)
        status_if_ref = semantic_entry_for_lexeme_on_line(source, entries, "status", status_if_line)
        status_return_ref = semantic_entry_for_lexeme_on_line(source, entries, "status", status_return_line)

        assert_equal "variable", status_decl.fetch("tokenType")
        assert_includes status_decl.fetch("modifierNames"), "declaration"
        assert_equal "variable", status_assign_ref.fetch("tokenType")
        refute_includes status_assign_ref.fetch("modifierNames"), "declaration"
        assert_equal "function", make_status_ref.fetch("tokenType")
        assert_equal "variable", status_if_ref.fetch("tokenType")
        assert_equal "variable", status_return_ref.fetch("tokenType")
      end
    end

    def test_semantic_tokens_do_not_let_generic_parameter_fallback_override_member_access
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_generic_parameter_property_test.mt"
        source = SOURCE_WITH_GENERIC_PARAMETER_AND_PROPERTY_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        property_access = semantic_entry_for_lexeme_on_line(source, entries, "status", 4)
        parameter_ref = semantic_entry_for_lexeme_on_line(source, entries, "status", 5)

        assert_equal "property", property_access.fetch("tokenType")
        assert_equal "parameter", parameter_ref.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_type_parameters_match_scrutinees_and_match_binders
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_generic_variant_test.mt"
        source = SOURCE_WITH_GENERIC_VARIANT_SEMANTICS
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        header_type_param = semantic_entry_for_lexeme_on_line(source, entries, "T", 0)
        field_type_param = semantic_entry_for_lexeme_on_line(source, entries, "T", 1)
        match_scrutinee = semantic_entry_for_lexeme_on_line(source, entries, "value", 5)
        match_binder = semantic_entry_for_lexeme_on_line(source, entries, "payload", 6)

        assert_equal "typeParameter", header_type_param.fetch("tokenType")
        assert_includes header_type_param.fetch("modifierNames"), "declaration"
        assert_equal "typeParameter", field_type_param.fetch("tokenType")
        assert_equal "parameter", match_scrutinee.fetch("tokenType")
        refute_includes match_scrutinee.fetch("modifierNames"), "declaration"
        assert_equal "variable", match_binder.fetch("tokenType")
        assert_includes match_binder.fetch("modifierNames"), "declaration"
      end
    end

    def test_semantic_tokens_classify_variant_members_payload_fields_and_generic_constructor_labels
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_variant_constructor_labels_test.mt"
        source = <<~MT
            variant Choice[T]:
                some(value: T)
                none

            variant Outcome[T, E]:
                success(value: T)
                failure(error: E)

            struct Entry[T]:
                key: T
                count: int

            function classify(entry: Entry[int]) -> Outcome[int, int]:
                let rebuilt = Entry[int](key = entry.key, count = entry.count)
                match Choice[int].some(value = rebuilt.count):
                    Choice.some as payload:
                        return Outcome[int, int].success(value = payload.value)
                    Choice.none:
                        return Outcome[int, int].failure(error = rebuilt.count)
        MT

        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        some_decl = semantic_entry_for_lexeme_on_line(source, entries, "some", 1)
        error_decl = semantic_entry_for_lexeme_on_line(source, entries, "error", 6)
        key_label = semantic_entry_for_lexeme_on_line(source, entries, "key", 13)
        count_label = semantic_entry_for_lexeme_on_line(source, entries, "count", 13)
        some_ctor = semantic_entry_for_lexeme_on_line(source, entries, "some", 14)
        some_match = semantic_entry_for_lexeme_on_line(source, entries, "some", 15)
        none_match = semantic_entry_for_lexeme_on_line(source, entries, "none", 17)
        failure_return = semantic_entry_for_lexeme_on_line(source, entries, "failure", 18)
        error_label = semantic_entry_for_lexeme_on_line(source, entries, "error", 18)

        assert_equal "enumMember", some_decl.fetch("tokenType")
        assert_includes some_decl.fetch("modifierNames"), "declaration"
        assert_equal "property", error_decl.fetch("tokenType")
        assert_includes error_decl.fetch("modifierNames"), "declaration"
        assert_equal "property", key_label.fetch("tokenType")
        assert_equal "property", count_label.fetch("tokenType")
        assert_equal "enumMember", some_ctor.fetch("tokenType")
        assert_equal "enumMember", some_match.fetch("tokenType")
        assert_equal "enumMember", none_match.fetch("tokenType")
        assert_equal "enumMember", failure_return.fetch("tokenType")
        assert_equal "property", error_label.fetch("tokenType")
      end
    end

    def test_semantic_tokens_fstring_delimiters_do_not_override_textmate
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_fstring_test.mt"
        source = SOURCE_WITH_FSTRING_INTERPOLATION
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        interpolation_line = source.lines.fetch(2)
        hash_index = interpolation_line.index('#{')
        rbrace_index = interpolation_line.index("}", hash_index)

        refute entries.any? { |entry| entry.fetch("line") == 2 && entry.fetch("startChar") == hash_index && entry.fetch("tokenType") == "operator" }
        refute entries.any? { |entry| entry.fetch("line") == 2 && entry.fetch("startChar") == (hash_index + 1) && entry.fetch("tokenType") == "operator" }
        refute entries.any? { |entry| entry.fetch("line") == 2 && entry.fetch("startChar") == rbrace_index && entry.fetch("tokenType") == "operator" }

        interpolation_name_entry = entries.find do |entry|
          entry.fetch("line") == 2 && interpolation_line[entry.fetch("startChar"), 4] == "name"
        end
        refute_nil interpolation_name_entry
        assert_equal "variable", interpolation_name_entry.fetch("tokenType")
      end
    end

    def test_semantic_tokens_classify_fstring_member_access_with_real_context
      protocol = Object.new
      protocol.define_singleton_method(:write_notification) { |_method, _params| nil }

      server = MilkTea::LSP::Server.new(protocol: protocol)
      init = server.send(:handle_initialize, { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_semantic_fstring_member_access_test.mt"
      source = SOURCE_WITH_FSTRING_MEMBER_INTERPOLATION

      server.send(:handle_did_open, {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = server.send(:handle_semantic_tokens_full, {
        "textDocument" => { "uri" => uri }
      })

      legend = init.fetch(:capabilities).fetch(:semanticTokensProvider).fetch(:legend)
      entries = decode_semantic_token_entries(response.fetch(:data), {
        "tokenTypes" => legend.fetch(:tokenTypes),
        "tokenModifiers" => legend.fetch(:tokenModifiers),
      })
      snapshot_entry = semantic_entry_for_lexeme_on_line(source, entries, "snapshot", 8)
      score_entry = semantic_entry_for_lexeme_on_line(source, entries, "score", 8)

      assert_equal "property", snapshot_entry.fetch("tokenType")
      assert_equal "property", score_entry.fetch("tokenType")
    ensure
      server&.send(:handle_shutdown, {})
    end

    def test_semantic_tokens_cover_multiline_heredoc_strings
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_heredoc_test.mt"
        source = SOURCE_WITH_PLAIN_HEREDOC_CSTRING
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)
        string_entries = entries.select { |entry| entry.fetch("tokenType") == "string" }
        covered_lines = string_entries.map { |entry| entry.fetch("line") }.uniq.sort

        assert_includes covered_lines, 0
        assert_includes covered_lines, 1
        assert_includes covered_lines, 2
        assert_includes covered_lines, 3
      end
    end

    def test_semantic_tokens_do_not_override_glsl_heredoc_body
      assert_embedded_heredoc_body_has_no_string_semantic_tokens(
        SOURCE_WITH_GLSL_HEREDOC_CSTRING,
        "file:///tmp/lsp_semantic_glsl_heredoc_test.mt"
      )
    end

    def test_semantic_tokens_do_not_override_alt_shader_tag_heredoc_body
      assert_embedded_heredoc_body_has_no_string_semantic_tokens(
        SOURCE_WITH_VERT_HEREDOC_CSTRING,
        "file:///tmp/lsp_semantic_vert_heredoc_test.mt"
      )
    end

    def test_semantic_tokens_do_not_override_json_heredoc_body
      assert_embedded_heredoc_body_has_no_string_semantic_tokens(
        SOURCE_WITH_JSON_HEREDOC_CSTRING,
        "file:///tmp/lsp_semantic_json_heredoc_test.mt"
      )
    end

    def test_semantic_tokens_do_not_override_jsonc_heredoc_body
      assert_embedded_heredoc_body_has_no_string_semantic_tokens(
        SOURCE_WITH_JSONC_HEREDOC_CSTRING,
        "file:///tmp/lsp_semantic_jsonc_heredoc_test.mt"
      )
    end

    def test_semantic_tokens_do_not_override_sql_heredoc_body
      assert_embedded_heredoc_body_has_no_string_semantic_tokens(
        SOURCE_WITH_SQL_HEREDOC_CSTRING,
        "file:///tmp/lsp_semantic_sql_heredoc_test.mt"
      )
    end

    def test_semantic_tokens_do_not_override_html_heredoc_cstring_body
      assert_embedded_heredoc_body_has_no_string_semantic_tokens(
        SOURCE_WITH_HTML_HEREDOC_CSTRING,
        "file:///tmp/lsp_semantic_html_cstring_heredoc_test.mt"
      )
    end

    def test_semantic_tokens_do_not_override_html_heredoc_string_body
      assert_embedded_heredoc_body_has_no_string_semantic_tokens(
        SOURCE_WITH_HTML_HEREDOC_STRING,
        "file:///tmp/lsp_semantic_html_string_heredoc_test.mt"
      )
    end

    def test_semantic_tokens_do_not_override_html_format_heredoc_body
      assert_embedded_heredoc_body_has_no_string_semantic_tokens(
        SOURCE_WITH_HTML_FORMAT_HEREDOC,
        "file:///tmp/lsp_semantic_html_format_heredoc_test.mt"
      )
    end

    def test_semantic_tokens_full_stays_within_latency_budget
      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        uri = "file:///tmp/lsp_semantic_latency_test.mt"
        source = <<~MT
          #{SOURCE_WITH_STR_BUFFER_METHODS}
          #{SOURCE_WITH_GENERIC_TYPE_SURFACES}
          #{SOURCE_WITH_FSTRING_INTERPOLATION}
        MT
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        elapsed_ms, response = measure_request_ms do
          client.send_request("textDocument/semanticTokens/full", {
            "textDocument" => { "uri" => uri }
          })
        end

        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        entries = decode_semantic_token_entries(response.fetch("result").fetch("data"), legend)

        assert entries.length >= 6, "expected semantic token entries for latency source"
        assert_operator elapsed_ms, :<, SEMANTIC_TOKENS_LATENCY_BUDGET_MS,
                        "semanticTokens/full took #{format("%.2f", elapsed_ms)}ms (budget #{SEMANTIC_TOKENS_LATENCY_BUDGET_MS}ms)"
      end
    end

  public

end
