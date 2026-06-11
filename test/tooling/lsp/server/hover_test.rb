# frozen_string_literal: true

require_relative "helpers"

class HoverTest < Minitest::Test
  include LSPServerTestHelpers

  def test_hover_includes_docs_source_and_range
    Dir.mktmpdir("milk-tea-lsp-hover") do |dir|
      source_path = File.join(dir, "main.mt")
      source = SOURCE_WITH_HOVER_DOCS
      File.write(source_path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source
          }
        })

        hover_response = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => 6, "character" => 11 }
        })

        hover_result = hover_response.fetch("result")
        hover_value = hover_result.dig("contents", "value")
        hover_range = hover_result.fetch("range")

        assert_includes hover_value, "function add(a: int, b: int) -> int"
        assert_includes hover_value, "Adds two values."
        assert_includes hover_value, "Used by main."
        assert_includes hover_value, "Defined at: [main.mt:3](#{uri}#L3)"

        assert_equal 6, hover_range.dig("start", "line")
        assert_equal 11, hover_range.dig("start", "character")
        assert_equal 14, hover_range.dig("end", "character")
      end
    end
  end

  def test_hover_returns_interface_info_for_local_implements_clause
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })

      uri = "file:///tmp/lsp_hover_interface_local.mt"
      source = SOURCE_WITH_LOCAL_INTERFACES
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      implements_line = source.lines.index { |line| line.include?("implements ScreenState") }
      interface_char = source.lines[implements_line].index("ScreenState") + 1

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => implements_line, "character" => interface_char },
      })

      hover_value = hover_response.dig("result", "contents", "value")
      assert_includes hover_value, "interface ScreenState"
      assert_includes hover_value, "editable function update(effect: int) -> void"
      assert_includes hover_value, "function draw(texture: int) -> void"
      assert_includes hover_value, "Shared gameplay contract."
      refute_includes hover_value, "local ScreenState"
    end
  end

  def test_hover_and_definition_on_imported_interface_jump_to_interface_declaration
    Dir.mktmpdir("milk-tea-lsp-interface-import") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      contracts_source = <<~MT
        ## Damage contract.
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

      root_uri = path_to_uri(dir)
      contracts_uri = path_to_uri(contracts_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source,
          }
        })

        implements_line = main_source.lines.index { |line| line.include?("contracts.Damageable") }
        interface_char = main_source.lines[implements_line].index("Damageable") + 1
        definition_line = contracts_source.lines.index { |line| line.include?("interface Damageable") }
        definition_char = contracts_source.lines[definition_line].index("Damageable")

        hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => implements_line, "character" => interface_char }
        })
        hover_value = hover.dig("result", "contents", "value")
        assert_includes hover_value, "interface Damageable"
        assert_includes hover_value, "editable function take_damage(amount: int) -> void"
        assert_includes hover_value, "Damage contract."
        assert_includes hover_value, "Defined at: [std/contracts.mt:#{definition_line + 1}](#{contracts_uri}#L#{definition_line + 1})"

        definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => implements_line, "character" => interface_char }
        })

        assert_equal contracts_uri, definition.dig("result", "uri")
        assert_equal definition_line, definition.dig("result", "range", "start", "line")
        assert_equal definition_char, definition.dig("result", "range", "start", "character")
      end
    end
  end

  def test_hover_shows_local_variable_type
    source = <<~MT
      function main() -> int:
          let value = 1
          return value
    MT

    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_local_type.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 2, "character" => 11 },
      })

      hover_value = hover_response.dig("result", "contents", "value")
      assert_includes hover_value, "let value: int (immutable)"
    end
  end

  def test_hover_shows_local_declaration_type
    source = <<~MT
      function main() -> int:
          let value = 1
          return value
    MT

    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_local_decl_type.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 1, "character" => 8 },
      })

      hover_value = hover_response.dig("result", "contents", "value")
      assert_includes hover_value, "let value: int (immutable)"
    end
  end

  def test_hover_shows_let_else_error_binding_declaration_type
    source = <<~MT


      function load() -> Result[int, int]:
          return Result[int, int].failure(error = 1)

      function main() -> int:
          let value = load() else as error:
              return error
          return value
    MT
        error_decl_line = source.lines.index { |line| line.include?("else as error") }
        error_decl_char = source.lines.fetch(error_decl_line).index("error") + 1

    Dir.mktmpdir("lsp_hover_let_else_error_decl") do |dir|
      path = File.join(dir, "main.mt")
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = "file://#{path}"
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source,
          },
        })

        hover_response = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => error_decl_line, "character" => error_decl_char },
        })

        hover_value = hover_response.dig("result", "contents", "value")
        assert_includes hover_value, "let error: int (immutable)"
      end
    end
  end

  def test_hover_shows_parameter_type
    source = <<~MT
      function main(value: int) -> int:
          return value
    MT

    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_param_type.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 1, "character" => 11 },
      })

      hover_value = hover_response.dig("result", "contents", "value")
      assert_includes hover_value, "parameter value: int (immutable)"
    end
  end

  def test_hover_shows_var_and_const_binding_kinds
    source = <<~MT
      const answer: int = 42
      var score: int = 0

      function main() -> int:
          score += 1
          return answer + score
    MT

    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_value_kind_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      const_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 5, "character" => 11 },
      })
      const_hover_value = const_hover.dig("result", "contents", "value")
      assert_includes const_hover_value, "const answer: int (immutable)"

      var_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 5, "character" => 20 },
      })
      var_hover_value = var_hover.dig("result", "contents", "value")
      assert_includes var_hover_value, "var score: int (mutable)"
    end
  end

  def test_hover_shows_declared_generic_parameter_type_in_generic_body
    source = <<~MT
      interface ScreenState:
          function update(effect: int) -> void

      struct TitleScreen implements ScreenState:
          ticks: int

      extending TitleScreen:
          function update(effect: int) -> void:
              let sink = effect

      function run_screen_frame[T implements ScreenState](screen: ref[T], effect: int) -> void:
          screen.update(effect)

      function main() -> int:
          var title = TitleScreen(ticks = 0)
          run_screen_frame(title, 1)
          return 0
    MT

    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_generic_param_type.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 11, "character" => 6 },
      })

      hover_value = hover_response.dig("result", "contents", "value")
      assert_includes hover_value, "parameter screen: ref[T] (immutable)"
      refute_includes hover_value, "TitleScreen"
    end
  end

  def test_hover_shows_builtin_default_value_signature
    source = SOURCE_WITH_FUNCTION_VALUE_AND_ZERO_SEMANTICS

    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_builtin_default_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      line = source.lines.index { |text| text.include?("default[Box]") }
      character = source.lines.fetch(line).rindex("default")

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => character },
      })

      zero_line = source.lines.index { |text| text.include?("zero[Box]") }
      zero_character = source.lines.fetch(zero_line).rindex("zero")

      zero_hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => zero_line, "character" => zero_character },
      })

      zero_hover_value = zero_hover_response.dig("result", "contents", "value")
      assert_includes zero_hover_value, "builtin zero[Box] -> Box"
      assert_includes zero_hover_value, "value form, not a callable"

      hover_value = hover_response.dig("result", "contents", "value")
      assert_includes hover_value, "builtin default[Box] -> Box"
      assert_includes hover_value, "requires an accessible zero-argument associated function `T.default()` that returns `T`"
      assert_includes hover_value, "value form, not a callable"
      refute_includes hover_value, "local default"
    end
  end

  def test_hover_shows_builtin_callable_signatures
    source = SOURCE_WITH_BUILTIN_CALLABLE_HOVER

    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_builtin_callable_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      array_line = source.lines.index { |text| text.include?("array[int, 2](1, 2)") }
      array_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => array_line, "character" => source.lines.fetch(array_line).index("array") },
      })
      array_hover_value = array_hover.dig("result", "contents", "value")
      assert_includes array_hover_value, "builtin array[int, 2](...) -> array[int, 2]"

      span_line = source.lines.index { |text| text.include?("span[int](data =") }
      span_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => span_line, "character" => source.lines.fetch(span_line).index("span") },
      })
      span_hover_value = span_hover.dig("result", "contents", "value")
      assert_includes span_hover_value, "builtin span[int](data = ..., len = ...) -> span[int]"

      ptr_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => span_line, "character" => source.lines.fetch(span_line).index("ptr_of") },
      })
      ptr_hover_value = ptr_hover.dig("result", "contents", "value")
      assert_includes ptr_hover_value, "builtin ptr_of(value) -> ptr[T]"

      ref_line = source.lines.index { |text| text.include?("ref_of(items[0])") }
      ref_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => ref_line, "character" => source.lines.fetch(ref_line).index("ref_of") },
      })
      ref_hover_value = ref_hover.dig("result", "contents", "value")
      assert_includes ref_hover_value, "builtin ref_of(value) -> ref[T]"

      read_line = source.lines.index { |text| text.include?("read(alias)") }
      read_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => read_line, "character" => source.lines.fetch(read_line).index("read") },
      })
      read_hover_value = read_hover.dig("result", "contents", "value")
      assert_includes read_hover_value, "builtin read(value) -> T"
    end
  end

  def test_hover_shows_builtin_associated_hook_signatures
    source = SOURCE_WITH_ASSOCIATED_HOOK_BUILTINS

    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_builtin_associated_hooks_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      hash_line = source.lines.index { |text| text.include?("let hashed = hash[Key](key)") }
      equal_line = source.lines.index { |text| text.include?("let same = equal[Key](key, other)") }
      order_line = source.lines.index { |text| text.include?("order[Key](key, other)") }

      hash_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => hash_line, "character" => source.lines.fetch(hash_line).index("hash[") + 1 },
      })
      hash_hover_value = hash_hover.dig("result", "contents", "value")
      assert_includes hash_hover_value, "builtin hash[Key](value) -> uint"
      assert_includes hash_hover_value, "lowers to `T.hash(value: const_ptr[T]) -> uint`"

      equal_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => equal_line, "character" => source.lines.fetch(equal_line).index("equal") + 1 },
      })
      equal_hover_value = equal_hover.dig("result", "contents", "value")
      assert_includes equal_hover_value, "builtin equal[Key](left, right) -> bool"

      order_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => order_line, "character" => source.lines.fetch(order_line).index("order") + 1 },
      })
      order_hover_value = order_hover.dig("result", "contents", "value")
      assert_includes order_hover_value, "builtin order[Key](left, right) -> int"
    end
  end

  def test_builtin_hover_info_describes_attribute_reflection_helpers
    source = <<~MT
      public attribute[field, callable] trace(name: str)

      struct Packet:
          @[trace("payload_len")]
          payload_len: uint

      @[trace("parse_packet")]
      function parse_packet() -> int:
          return 0

      function main() -> ptr_uint:
          let field_present = has_attribute(field_of(Packet, payload_len), trace)
          let callable_present = has_attribute(callable_of(parse_packet), trace)
          if field_present and callable_present:
              return attribute_arg[str](attribute_of(field_of(Packet, payload_len), trace), name).len
          return 0
    MT

    tokens = MilkTea::Lexer.lex(source, path: "/tmp/lsp_builtin_attribute_reflection_hover.mt")
    server = MilkTea::LSP::Server.new(protocol: RecordingProtocol.new)
    begin
      fetch_builtin_hover = lambda do |lexeme, occurrence = 0|
        token_index = tokens.each_index.select { |index| tokens[index].lexeme == lexeme }.fetch(occurrence)
        server.send(:builtin_hover_info, lexeme, tokens, token_index)
      end

      field_hover = fetch_builtin_hover.call("field_of")
      assert_includes field_hover.fetch(:signature), "builtin field_of(Type, field_name) -> field_handle"
      assert_includes field_hover.fetch(:docs), "compile-time handle for the named field"

      callable_hover = fetch_builtin_hover.call("callable_of")
      assert_includes callable_hover.fetch(:signature), "builtin callable_of(name) -> callable_handle"
      assert_includes callable_hover.fetch(:docs), "compile-time handle for a callable declaration name"

      has_attribute_hover = fetch_builtin_hover.call("has_attribute")
      assert_includes has_attribute_hover.fetch(:signature), "builtin has_attribute(target, attribute_name) -> bool"
      assert_includes has_attribute_hover.fetch(:docs), "checks at compile time whether the resolved attribute is applied"

      attribute_of_hover = fetch_builtin_hover.call("attribute_of")
      assert_includes attribute_of_hover.fetch(:signature), "builtin attribute_of(target, attribute_name) -> attribute_handle"
      assert_includes attribute_of_hover.fetch(:docs), "use `has_attribute(...)` when absence is expected"

      attribute_arg_hover = fetch_builtin_hover.call("attribute_arg")
      assert_includes attribute_arg_hover.fetch(:signature), "builtin attribute_arg[str](attribute, param_name) -> str"
      assert_includes attribute_arg_hover.fetch(:docs), "`T` must exactly match the declared parameter type"
    ensure
      server&.send(:stop_diagnostics_workers)
    end
  end

  def test_hover_and_definition_resolve_fstring_local_bindings
    source = <<~'MT'
      function main() -> int:
          let name = "milk"
          let msg = f"hello #{name}"
          return 0
    MT

    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_fstring_local_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source,
        },
      })

      line = source.lines.index { |text| text.include?('#{name}') }
      character = source.lines.fetch(line).index("name")

      hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => character },
      })
      hover_value = hover.dig("result", "contents", "value")
      assert_includes hover_value, "let name: str (immutable)"

      definition = client.send_request("textDocument/definition", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => character },
      })
      definition_result = definition.fetch("result")

      assert_equal uri, definition_result.fetch("uri")
      assert_equal 1, definition_result.dig("range", "start", "line")
    end
  end

  def test_hover_response_stays_within_latency_budget
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_latency_test.mt"
      source = SOURCE_WITH_HOVER_DOCS
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source
        }
      })

      elapsed_ms, response = measure_request_ms do
        client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => 6, "character" => 11 }
        })
      end

      assert response.fetch("result"), "expected non-nil hover result"
      assert_operator elapsed_ms, :<, HOVER_LATENCY_BUDGET_MS,
                      "hover took #{format("%.2f", elapsed_ms)}ms (budget #{HOVER_LATENCY_BUDGET_MS}ms)"
    end
  end

  def test_hover_ignores_plain_hash_comments_for_docs
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_plain_comment_test.mt"
      source = SOURCE_WITH_HOVER_PLAIN_COMMENT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source
        }
      })

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 5, "character" => 11 }
      })

      hover_value = hover_response.dig("result", "contents", "value")
      refute_includes hover_value, "Not documentation."
    end
  end

  def test_hover_doc_block_requires_no_blank_line_before_definition
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_doc_gap_test.mt"
      source = SOURCE_WITH_HOVER_DOC_GAP
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source
        }
      })

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 6, "character" => 11 }
      })

      hover_value = hover_response.dig("result", "contents", "value")
      refute_includes hover_value, "Detached doc."
    end
  end

  def test_hover_defined_at_is_markdown_link
    Dir.mktmpdir("milk-tea-lsp-hover-link") do |dir|
      source_path = File.join(dir, "main.mt")
      source = SOURCE_WITH_HOVER_DOCS
      File.write(source_path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(source_path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => source
          }
        })

        hover_response = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => 6, "character" => 11 }
        })

        hover_value = hover_response.dig("result", "contents", "value")

        # Verify only the source path segment is linked
        assert_includes hover_value, "Defined at: [main.mt:3](#{uri}#L3)"
      end
    end
  end

  def test_hover_renders_structured_doc_tag_sections
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})

      uri = "file:///tmp/lsp_hover_structured_docs_test.mt"
      source = SOURCE_WITH_STRUCTURED_DOC_TAGS
      client.send_notification("textDocument/didOpen", {
        "textDocument" => {
          "uri" => uri,
          "languageId" => "milk-tea",
          "version" => 1,
          "text" => source
        }
      })

      hover_response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 9, "character" => 11 }
      })

      hover_value = hover_response.dig("result", "contents", "value")
      assert_includes hover_value, "Adds two values."
      assert_includes hover_value, "**Parameters**"
      assert_includes hover_value, "- `a`: first addend"
      assert_includes hover_value, "- `b`: second addend"
      assert_includes hover_value, "**Returns**"
      assert_includes hover_value, "sum of both values"
      assert_includes hover_value, "**See Also**"
      assert_includes hover_value, "[math reference](https://example.com/math)"
    end
  end

  def test_hover_on_imported_type_static_method_uses_qualified_receiver
    Dir.mktmpdir("milk-tea-lsp-hover-imported-type") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      foo_source = <<~MT
        public struct Point:
            x: int
            y: int

        extending Point:
            public static function zero() -> int:
                return 0
      MT
      main_source = <<~MT
        import std.foo as foo

        public function main() -> int:
            return foo.Point.zero()
      MT

      foo_path = File.join(std_dir, "foo.mt")
      main_path = File.join(dir, "main.mt")
      File.write(foo_path, foo_source)
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      foo_uri = path_to_uri(foo_path)
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
        definition_line = foo_source.lines.index { |line| line.include?("static function zero") }

        hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        hover_value = hover.dig("result", "contents", "value")
        assert_includes hover_value, "static function zero() -> int"
        assert_includes hover_value, "Defined at: [std/foo.mt:#{definition_line + 1}](#{foo_uri}#L#{definition_line + 1})"
      end
    end
  end

  def test_hover_on_imported_module_member_uses_loose_workspace_root_for_import_resolution
    Dir.mktmpdir("milk-tea-lsp-hover-imported-module") do |dir|
      lib_path = File.join(dir, "demo", "lib.mt")
      main_path = File.join(dir, "main.mt")
      FileUtils.mkdir_p(File.join(dir, "demo"))

      lib_source = <<~MT
        public function greet() -> int:
            return 1
      MT
      main_source = <<~MT
        import demo.lib as lib

        function main() -> int:
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
        call_char = main_source.lines[call_line].index("greet")

        hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        hover_value = hover.dig("result", "contents", "value")
        assert_includes hover_value, "function greet() -> int"
        assert_includes hover_value, "Defined at: [demo/lib.mt:1](#{lib_uri}#L1)"
      end
    end
  end

  def test_hover_and_completion_still_work_for_resolved_imports_when_another_import_is_missing
    Dir.mktmpdir("milk-tea-lsp-missing-import-partial-analysis") do |dir|
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
        version = "0.1.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(ui_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      main_path = File.join(app_src_dir, "main.mt")
      main_source = <<~MT
        import teefan.ui.layout as layout
        import test

        function main() -> int:
            return layout.default_width()
      MT
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      main_uri = path_to_uri(main_path)
      dot_source = main_source.sub("return layout.default_width()", "return layout.")
      dot_line = dot_source.lines.index { |line| line.include?("return layout.") }
      dot_char = dot_source.lines.fetch(dot_line).chomp.length
      hover_line = main_source.lines.index { |line| line.include?("layout.default_width") }
      hover_char = main_source.lines.fetch(hover_line).index("layout") + 1

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source,
          }
        })

        hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => hover_line, "character" => hover_char },
        })
        hover_value = hover.dig("result", "contents", "value")
        assert_includes hover_value, "module teefan.ui.layout"

        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => main_uri, "version" => 2 },
          "contentChanges" => [{ "text" => dot_source }],
        })

        completion = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => dot_line, "character" => dot_char },
        })
        labels = completion.fetch("result").fetch("items").map { |item| item.fetch("label") }

        assert_includes labels, "default_width"
      end
    end
  end

  def test_hover_and_completion_still_work_after_invalid_top_level_declaration
    Dir.mktmpdir("milk-tea-lsp-top-level-parse-recovery") do |dir|
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
        version = "0.1.0"
        kind = "library"
        source_root = "src"
      TOML

      File.write(File.join(ui_src_dir, "layout.mt"), <<~MT)
        public function default_width() -> int:
            return 10
      MT

      main_path = File.join(app_src_dir, "main.mt")
      main_source = <<~MT
        import teefan.ui.layout as layout

        const board_height: int = 20a
        const board_cells: int = 200

        function main() -> int:
        return layout.default_width() + board_height + board_cells
      MT
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      main_uri = path_to_uri(main_path)
      dot_source = main_source.sub("return layout.default_width() + board_height + board_cells", "return layout.")
      dot_line = dot_source.lines.index { |line| line.include?("return layout.") }
      dot_char = dot_source.lines.fetch(dot_line).chomp.length
      hover_line = main_source.lines.index { |line| line.include?("layout.default_width") }
      hover_char = main_source.lines.fetch(hover_line).index("layout") + 1
      board_height_char = main_source.lines.fetch(hover_line).index("board_height") + 1

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source,
          }
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri },
        })
        messages = diagnostics.fetch("result").fetch("items").map { |item| item.fetch("message") }
        assert_includes messages, "expected end of statement at #{main_uri}:3:29"

        board_height_hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => hover_line, "character" => board_height_char },
        })
        board_height_hover_value = board_height_hover.dig("result", "contents", "value")
        assert_includes board_height_hover_value, "const board_height: int (immutable)"

        hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => hover_line, "character" => hover_char },
        })
        hover_value = hover.dig("result", "contents", "value")
        assert_includes hover_value, "module teefan.ui.layout"

        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => main_uri, "version" => 2 },
          "contentChanges" => [{ "text" => dot_source }],
        })

        completion = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => dot_line, "character" => dot_char },
        })
        labels = completion.fetch("result").fetch("items").map { |item| item.fetch("label") }

        assert_includes labels, "default_width"
      end
    end
  end

  def test_hover_still_works_after_invalid_statement_in_block
    Dir.mktmpdir("milk-tea-lsp-block-parse-recovery") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        function main() -> int:
            let value = 1
            let broken = 20a
            return value
      MT
      File.write(path, source)
      hover_line = source.lines.index { |line| line.include?("return value") }
      hover_char = source.lines.fetch(hover_line).index("value") + 1

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
        assert_includes messages, "expected end of statement at #{uri}:3:20"

        hover_response = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => hover_line, "character" => hover_char },
        })

        hover_value = hover_response.dig("result", "contents", "value")
        assert_includes hover_value, "let value: int (immutable)"
      end
    end
  end

  def test_hover_and_semantic_tokens_still_work_after_lex_indentation_error
    Dir.mktmpdir("milk-tea-lsp-lex-indentation-recovery") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        function main() -> int:
            let value = 1
            return value
      MT
      broken_source = <<~MT
        function main() -> int:
            let value = 1
             return value
      MT
      File.write(path, source)

      hover_line = broken_source.lines.index { |line| line.include?("return value") }
      hover_char = broken_source.lines.fetch(hover_line).index("value")

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

        healthy_tokens = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri },
        }).dig("result", "data")
        assert_operator healthy_tokens.length, :>, 0

        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => uri, "version" => 2 },
          "contentChanges" => [{ "text" => broken_source }],
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => uri },
        })
        messages = diagnostics.fetch("result").fetch("items").map { |item| item.fetch("message") }
        assert messages.any? { |message| message.include?("indentation must use multiples of 4 spaces") }

        hover_response = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => hover_line, "character" => hover_char },
        })
        hover_value = hover_response.dig("result", "contents", "value")
        assert_includes hover_value, "let value: int (immutable)"

        semantic_tokens = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri },
        }).dig("result", "data")
        assert_operator semantic_tokens.length, :>, 0
      end
    end
  end

  def test_hover_and_semantic_tokens_fall_back_after_unterminated_string_edit
    Dir.mktmpdir("milk-tea-lsp-unterminated-string-fallback") do |dir|
      path = File.join(dir, "main.mt")
      healthy_source = <<~MT
        function main() -> int:
            let value = 1
            return value

        function after() -> int:
            return 2
      MT
      broken_source = <<~MT
        function main() -> int:
            let value = 1
            return value

        function after() -> int:
            return "oops
      MT
      File.write(path, healthy_source)

      hover_line = healthy_source.lines.index { |line| line.include?("return value") }
      hover_char = healthy_source.lines.fetch(hover_line).index("value")

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => healthy_source,
          },
        })

        baseline_tokens = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri },
        }).dig("result", "data")
        assert_operator baseline_tokens.length, :>, 0

        baseline_hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => hover_line, "character" => hover_char },
        })
        baseline_hover_value = baseline_hover.dig("result", "contents", "value")
        assert_includes baseline_hover_value, "let value: int (immutable)"

        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => uri, "version" => 2 },
          "contentChanges" => [{ "text" => broken_source }],
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => uri },
        })
        messages = diagnostics.fetch("result").fetch("items").map { |item| item.fetch("message") }
        assert messages.any? { |message| message.include?("unterminated string literal") }

        hover_after_break = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => hover_line, "character" => hover_char },
        })
        hover_after_break_value = hover_after_break.dig("result", "contents", "value")
        assert_includes hover_after_break_value, "let value: int (immutable)"

        tokens_after_break = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri },
        }).dig("result", "data")
        assert_operator tokens_after_break.length, :>, 0
      end
    end
  end

  def test_hover_and_semantic_tokens_still_work_after_tab_indentation_error
    Dir.mktmpdir("milk-tea-lsp-tab-indentation-recovery") do |dir|
      path = File.join(dir, "main.mt")
      broken_source = <<~MT
        function main() -> int:
            let value = 1
	    return value
      MT
      File.write(path, broken_source)

      hover_line = broken_source.lines.index { |line| line.include?("return value") }
      hover_char = broken_source.lines.fetch(hover_line).index("value")

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => broken_source,
          },
        })

        hover_response = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => hover_line, "character" => hover_char },
        })
        hover_value = hover_response.dig("result", "contents", "value")
        assert_includes hover_value, "let value: int (immutable)"

        semantic_tokens = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri },
        }).dig("result", "data")
        assert_operator semantic_tokens.length, :>, 0
      end
    end
  end

  def test_hover_still_works_after_invalid_typed_local_declaration
    Dir.mktmpdir("milk-tea-lsp-typed-local-recovery") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        struct Point:
            x: int
            y: int

        extending Point:
            function length() -> int:
                return this.x + this.y

        function main() -> int:
            let p: Point = 20a
            return p.x
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
        assert_includes messages, "expected end of statement at #{uri}:10:22"

        hover_line = source.lines.index { |line| line.include?("return p.x") }
        p_char = source.lines.fetch(hover_line).index("p")
        x_char = source.lines.fetch(hover_line).index("x")

        p_hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => hover_line, "character" => p_char },
        })
        p_hover_value = p_hover.dig("result", "contents", "value")
        assert_includes p_hover_value, "let p: Point (immutable)"
        assert_includes p_hover_value, "From main"

        x_hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => hover_line, "character" => x_char },
        })
        x_hover_value = x_hover.dig("result", "contents", "value")
        assert_includes x_hover_value, "field x: int"
      end
    end
  end

  def test_hover_still_works_after_invalid_untyped_local_declaration
    Dir.mktmpdir("milk-tea-lsp-untyped-local-recovery") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        function main() -> int:
            let value = 20a
            return value
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
        assert_includes messages, "expected end of statement at #{uri}:2:19"

        hover_response = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => 2, "character" => 11 },
        })

        hover_value = hover_response.dig("result", "contents", "value")
        assert_includes hover_value, "let value: <error> (immutable)"
      end
    end
  end

  def test_hover_still_works_after_invalid_let_else_declaration
    Dir.mktmpdir("milk-tea-lsp-let-else-recovery") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        function main(handle: ptr[int]?) -> int:
            let value = handle else as error
                return 1
            unsafe:
                return read(value)
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

        hover_line = source.lines.index { |line| line.include?("read(value)") }
        hover_char = source.lines.fetch(hover_line).index("value")

        hover_response = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => hover_line, "character" => hover_char },
        })

        hover_value = hover_response.dig("result", "contents", "value")
        assert_includes hover_value, "let value: ptr[int] (immutable)"
      end
    end
  end

  def test_hover_works_inside_invalid_block_header_body
    Dir.mktmpdir("milk-tea-lsp-error-block-hover") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        function main() -> int:
            let value = 1
            unsafe
                let inner = value
                return inner
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

        hover_line = source.lines.index { |line| line.include?("return inner") }
        hover_char = source.lines.fetch(hover_line).index("inner")

        hover_response = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => hover_line, "character" => hover_char },
        })

        hover_value = hover_response.dig("result", "contents", "value")
        assert_includes hover_value, "let inner: int (immutable)"
      end
    end
  end

  def test_hover_uses_error_type_for_match_binding_when_scrutinee_is_missing
    Dir.mktmpdir("milk-tea-lsp-invalid-match-scrutinee-hover") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT
        struct Point:
            x: int

        variant MaybePoint:
            some(value: Point)
            none

        function main() -> int:
            match:
                MaybePoint.some as payload:
                    return payload
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
        assert messages.any? { |message| message.include?("expected expression") }

        hover_line = source.lines.index { |line| line.include?("return payload") }
        hover_char = source.lines.fetch(hover_line).index("payload")

        hover_response = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => uri },
          "position" => { "line" => hover_line, "character" => hover_char },
        })

        hover_value = hover_response.dig("result", "contents", "value")
        assert_includes hover_value, "local payload: <error> (mutable)"
      end
    end
  end

  def test_hover_and_definition_locked_uses_package_lock_when_manifest_dependencies_drift
    Dir.mktmpdir("milk-tea-lsp-locked-hover-definition") do |dir|
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

      ui_source = <<~MT
        public function default_width() -> int:
            return 10
      MT
      main_source = <<~MT
        import teefan.ui.layout as duel_ui

        function main() -> int:
            return duel_ui.default_width()
      MT

      main_path = File.join(app_src_dir, "main.mt")
      ui_path = File.join(ui_src_dir, "layout.mt")
      File.write(main_path, main_source)
      File.write(ui_path, ui_source)

      MilkTea::PackageLock.write(app_root)

      File.write(File.join(app_root, "package.toml"), <<~TOML)
        [package]
        name = "snake_duel"
        version = "0.1.0"
        source_root = "src"
      TOML

      root_uri = path_to_uri(dir)
      main_uri = path_to_uri(main_path)
      ui_uri = path_to_uri(ui_path)

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

        call_line = main_source.lines.index { |line| line.include?("duel_ui.default_width") }
        call_char = main_source.lines.fetch(call_line).index("default_width") + 1
        definition_line = ui_source.lines.index { |line| line.include?("public function default_width") }
        definition_char = ui_source.lines.fetch(definition_line).index("default_width")

        hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        hover_value = hover.dig("result", "contents", "value")
        assert_includes hover_value, "function default_width() -> int"
        assert_includes hover_value, "Defined at: [libs/ui/src/teefan/ui/layout.mt:#{definition_line + 1}](#{ui_uri}#L#{definition_line + 1})"

        definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        assert_equal ui_uri, definition.dig("result", "uri")
        assert_equal definition_line, definition.dig("result", "range", "start", "line")
        assert_equal definition_char, definition.dig("result", "range", "start", "character")
      end
    end
  end

  def test_hover_frozen_stops_using_stale_facts_after_manifest_watched_change
    Dir.mktmpdir("milk-tea-lsp-frozen-hover-watch") do |dir|
      app_root = File.join(dir, "apps", "snake-duel")
      ui_root = File.join(dir, "libs", "ui")
      app_src_dir = File.join(app_root, "src", "snake_duel")
      ui_src_dir = File.join(ui_root, "src", "teefan", "ui")

      FileUtils.mkdir_p(app_src_dir)
      FileUtils.mkdir_p(ui_src_dir)

      manifest_path = File.join(app_root, "package.toml")
      manifest_uri = path_to_uri(manifest_path)

      File.write(manifest_path, <<~TOML)
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

      root_uri = path_to_uri(dir)
      main_path = File.join(app_src_dir, "main.mt")
      main_uri = path_to_uri(main_path)
      call_line = main_source.lines.index { |line| line.include?("duel_ui.default_width") }
      call_char = main_source.lines.fetch(call_line).index("default_width") + 1

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

        first_hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })
        first_hover_value = first_hover.dig("result", "contents", "value")

        assert_includes first_hover_value, "function default_width() -> int"

        File.write(manifest_path, <<~TOML)
          [package]
          name = "snake_duel"
          version = "0.1.0"
          source_root = "src"
        TOML

        client.send_notification("workspace/didChangeWatchedFiles", {
          "changes" => [{ "uri" => manifest_uri, "type" => 2 }]
        })

        diagnostics = client.send_request("textDocument/diagnostic", {
          "textDocument" => { "uri" => main_uri }
        })
        diagnostic_messages = diagnostics.fetch("result").fetch("items").map { |item| item["message"] }

        assert diagnostic_messages.any? { |message| message.include?("package.lock is out of date") },
               "expected frozen diagnostics after watched manifest drift, got: #{diagnostic_messages.inspect}"

        second_hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        assert_nil second_hover["result"]
      end
    end
  end

  def test_hover_returns_method_info_for_method_name
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_method_hover_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_METHODS }
      })
      # Line 5 (0-based) is "    function zero() -> int:", 'zero' starts at character 13.
      response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 5, "character" => 13 }
      })
      hover_value = response.dig("result", "contents", "value")
      assert_includes hover_value, "function zero() -> int"
      refute_includes hover_value, "local zero"
    end
  end

  def test_hover_formats_builtin_type_without_redundant_alias
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_builtin_type_hover_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })

      response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 0, "character" => 16 }
      })
      hover_value = response.dig("result", "contents", "value")
      assert_includes hover_value, "type int"
      refute_includes hover_value, "type int = int"
    end
  end

  def test_hover_returns_field_info_for_field_declarations
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_field_declaration_hover_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE }
      })

      x_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 1, "character" => 4 }
      })
      x_hover_value = x_hover.dig("result", "contents", "value")
      assert_includes x_hover_value, "x: float"
      refute_includes x_hover_value, "local x"

      y_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 2, "character" => 4 }
      })
      y_hover_value = y_hover.dig("result", "contents", "value")
      assert_includes y_hover_value, "y: float"
      refute_includes y_hover_value, "local y"
    end
  end

  def test_hover_returns_field_info_for_member_chain_segments
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_member_chain_hover_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_MEMBER_CHAIN_HOVER }
      })

      active_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 8, "character" => 20 }
      })
      active_hover_value = active_hover.dig("result", "contents", "value")
      assert_includes active_hover_value, "field active: Piece"

      kind_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 8, "character" => 27 }
      })
      kind_hover_value = kind_hover.dig("result", "contents", "value")
      assert_includes kind_hover_value, "field kind: int"
    end
  end

  def test_hover_and_definition_resolve_imported_generic_member_chain_segments
    Dir.mktmpdir("milk-tea-lsp-imported-generic-member") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      foo_source = <<~MT
        public struct Bucket[K, V]:
            value: V

        extending Bucket[K, V]:
            public editable function get_or_insert(key: K, value: V) -> ptr[V]:
                let _ = key
                this.value = value
                return ptr_of(this.value)
      MT

      main_source = <<~MT
        import std.foo as foo

        struct Counter[T]:
            values: foo.Bucket[T, ptr_uint]

        extending Counter[T]:
            editable function add(value: T) -> ptr_uint:
                let current = this.values.get_or_insert(value, 0)
                unsafe:
                    return read(current)
      MT

      foo_path = File.join(std_dir, "foo.mt")
      main_path = File.join(dir, "main.mt")
      File.write(foo_path, foo_source)
      File.write(main_path, main_source)

      root_uri = path_to_uri(dir)
      foo_uri = path_to_uri(foo_path)
      main_uri = path_to_uri(main_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => main_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => main_source,
          }
        })

        access_line = main_source.lines.index { |line| line.include?("this.values.get_or_insert") }
        access_text = main_source.lines.fetch(access_line)
        values_char = access_text.index("values") + 1
        method_char = access_text.index("get_or_insert") + 1

        field_definition_line = main_source.lines.index { |line| line.include?("values: foo.Bucket") }
        field_definition_char = main_source.lines.fetch(field_definition_line).index("values")
        method_definition_line = foo_source.lines.index { |line| line.include?("function get_or_insert") }
        method_definition_char = foo_source.lines.fetch(method_definition_line).index("get_or_insert")

        values_hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => access_line, "character" => values_char }
        })
        values_hover_value = values_hover.dig("result", "contents", "value")
        assert_includes values_hover_value, "field values: Bucket[T, ptr_uint]"
        assert_includes values_hover_value, "From std.foo"

        method_hover = client.send_request("textDocument/hover", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => access_line, "character" => method_char }
        })
        method_hover_value = method_hover.dig("result", "contents", "value")
        assert_includes method_hover_value, "editable function get_or_insert(key: K, value: V) -> ptr[V]"
        assert_includes method_hover_value, "Defined at: [std/foo.mt:#{method_definition_line + 1}](#{foo_uri}#L#{method_definition_line + 1})"

        values_definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => access_line, "character" => values_char }
        })
        values_definition_result = values_definition.fetch("result")
        assert_equal main_uri, values_definition_result.fetch("uri")
        assert_equal field_definition_line, values_definition_result.dig("range", "start", "line")
        assert_equal field_definition_char, values_definition_result.dig("range", "start", "character")

        method_definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => access_line, "character" => method_char }
        })
        method_definition_result = method_definition.fetch("result")
        assert_equal foo_uri, method_definition_result.fetch("uri")
        assert_equal method_definition_line, method_definition_result.dig("range", "start", "line")
        assert_equal method_definition_char, method_definition_result.dig("range", "start", "character")
      end
    end
  end

  def test_hover_and_definition_resolve_fstring_member_access_segments_in_tetris
    with_server do |client|
      client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
      client.send_notification("initialized", {})

      source_path = File.expand_path("projects/tetris/src/main.mt", Dir.pwd)
      uri = path_to_uri(source_path)
      source = File.read(source_path)
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      line = source.lines.index { |text| text.include?('f"Score  #{this.snapshot.score}"') }
      line_text = source.lines.fetch(line)

      snapshot_character = line_text.index("snapshot")
      snapshot_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => snapshot_character }
      })
      snapshot_hover_value = snapshot_hover.dig("result", "contents", "value")
      assert_includes snapshot_hover_value, "field snapshot: Game"
      assert_includes snapshot_hover_value, "From main"

      snapshot_definition = client.send_request("textDocument/definition", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => snapshot_character }
      })
      snapshot_result = snapshot_definition.fetch("result")
      snapshot_line = source.lines.index { |text| text == "    snapshot: Game\n" }
      assert_equal uri, snapshot_result.fetch("uri")
      assert_equal snapshot_line, snapshot_result.dig("range", "start", "line")

      score_character = line_text.rindex("score")
      score_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => score_character }
      })
      score_hover_value = score_hover.dig("result", "contents", "value")
      assert_includes score_hover_value, "field score: int"

      score_definition = client.send_request("textDocument/definition", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => score_character }
      })
      score_result = score_definition.fetch("result")
      score_line = source.lines.index { |text| text == "    score: int\n" }
      assert_equal uri, score_result.fetch("uri")
      assert_equal score_line, score_result.dig("range", "start", "line")
    end
  end

  def test_hover_returns_method_info_for_member_access_segments
    with_server do |client|
      client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
      client.send_notification("initialized", {})

      source_path = File.expand_path("projects/tetris/src/main.mt", Dir.pwd)
      uri = path_to_uri(source_path)
      source = File.read(source_path)
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      line = source.lines.index { |text| text.include?("this.reset()") }
      character = source.lines.fetch(line).index("reset")

      hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => character }
      })
      hover_value = hover.dig("result", "contents", "value")

      assert_includes hover_value, "editable function reset() -> void"
      refute_includes hover_value, "local reset"
    end
  end

  def test_hover_returns_field_info_for_named_constructor_labels
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_named_constructor_label_hover_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_PARAMETER_AND_LABEL_SEMANTICS }
      })

      x_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 5, "character" => 21 }
      })
      x_hover_value = x_hover.dig("result", "contents", "value")
      assert_includes x_hover_value, "x: int"
      refute_includes x_hover_value, "local x"

      y_hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 5, "character" => 35 }
      })
      y_hover_value = y_hover.dig("result", "contents", "value")
      assert_includes y_hover_value, "y: int"
      refute_includes y_hover_value, "local y"
    end
  end

  def test_hover_and_definition_resolve_imported_enum_members
    with_server do |client|
      client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
      client.send_notification("initialized", {})

      source_path = File.expand_path("projects/tetris/src/main.mt", Dir.pwd)
      uri = path_to_uri(source_path)
      source = File.read(source_path)
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      line = source.lines.index { |text| text.include?("KEY_ENTER") }
      character = source.lines.fetch(line).index("KEY_ENTER")

      hover = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => character }
      })
      hover_value = hover.dig("result", "contents", "value")
      assert_includes hover_value, "KEY_ENTER"
      assert_includes hover_value, "KeyboardKey"
      assert_includes hover_value, "From rl"
      assert_includes hover_value, "257"
      assert_includes hover_value, "std/c/raylib.mt"

      definition = client.send_request("textDocument/definition", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => character }
      })
      definition_result = definition.fetch("result")

      expected_path = File.expand_path("std/c/raylib.mt", Dir.pwd)
      expected_line = File.readlines(expected_path).index { |text| text.include?("KEY_ENTER = 257") }
      assert_equal path_to_uri(expected_path), definition_result.fetch("uri")
      assert_equal expected_line, definition_result.dig("range", "start", "line")
    end
  end

end
