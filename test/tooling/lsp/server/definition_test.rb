# frozen_string_literal: true

require_relative "helpers"

class DefinitionTest < Minitest::Test
  include LSPServerTestHelpers

  def test_implementation_on_interface_returns_implementing_type_locations
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_interface_implementation_test.mt"
      source = SOURCE_WITH_LOCAL_INTERFACES
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      interface_line = source.lines.index { |line| line.include?("interface ScreenState") }
      interface_char = source.lines[interface_line].index("ScreenState") + 1
      title_line = source.lines.index { |line| line.include?("struct TitleScreen") }
      title_char = source.lines[title_line].index("TitleScreen")
      pause_line = source.lines.index { |line| line.include?("struct PauseScreen") }
      pause_char = source.lines[pause_line].index("PauseScreen")

      implementation = client.send_request("textDocument/implementation", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => interface_line, "character" => interface_char }
      })

      starts = implementation.fetch("result").map do |location|
        [location.fetch("uri"), location.dig("range", "start", "line"), location.dig("range", "start", "character")]
      end

      assert_includes starts, [uri, title_line, title_char]
      assert_includes starts, [uri, pause_line, pause_char]
    end
  end

  def test_implementation_on_interface_method_returns_implementing_method_locations
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_interface_method_implementation_test.mt"
      source = SOURCE_WITH_LOCAL_INTERFACES
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      interface_line = source.lines.index { |line| line.include?("editable function update(effect: int) -> void") }
      interface_char = source.lines[interface_line].index("update") + 1

      update_lines = source.lines.each_index.select do |index|
        source.lines[index].include?("editable function update(effect: int):")
      end
      title_line, pause_line = update_lines
      title_char = source.lines[title_line].index("update")
      pause_char = source.lines[pause_line].index("update")

      implementation = client.send_request("textDocument/implementation", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => interface_line, "character" => interface_char }
      })

      starts = implementation.fetch("result").map do |location|
        [location.fetch("uri"), location.dig("range", "start", "line"), location.dig("range", "start", "character")]
      end

      assert_includes starts, [uri, title_line, title_char]
      assert_includes starts, [uri, pause_line, pause_char]
    end
  end

  def test_implementation_on_imported_interface_method_returns_implementing_method_locations
    Dir.mktmpdir("milk-tea-lsp-interface-method-import") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      contracts_source = <<~MT
        public interface Damageable:
            editable function take_damage(amount: int) -> void
      MT
      entities_source = <<~MT
        import std.contracts as contracts

        public struct NPC implements contracts.Damageable:
            hp: int

        extending NPC:
            public editable function take_damage(amount: int):
                this.hp -= amount
      MT

      contracts_path = File.join(std_dir, "contracts.mt")
      entities_path = File.join(std_dir, "entities.mt")
      File.write(contracts_path, contracts_source)
      File.write(entities_path, entities_source)

      root_uri = path_to_uri(dir)
      contracts_uri = path_to_uri(contracts_path)
      entities_uri = path_to_uri(entities_path)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => {
            "uri" => contracts_uri,
            "languageId" => "milk-tea",
            "version" => 1,
            "text" => contracts_source
          }
        })

        interface_line = contracts_source.lines.index { |line| line.include?("take_damage") }
        interface_char = contracts_source.lines[interface_line].index("take_damage") + 1
        method_line = entities_source.lines.index { |line| line.include?("editable function take_damage") }
        method_char = entities_source.lines[method_line].index("take_damage")

        implementation = client.send_request("textDocument/implementation", {
          "textDocument" => { "uri" => contracts_uri },
          "position" => { "line" => interface_line, "character" => interface_char }
        })

        starts = implementation.fetch("result").map do |location|
          [location.fetch("uri"), location.dig("range", "start", "line"), location.dig("range", "start", "character")]
        end

        assert_includes starts, [entities_uri, method_line, method_char]
      end
    end
  end

  def test_declaration_and_type_definition_delegate_to_definition_location
    with_shared_server do |client|
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
      assert_equal 9, declaration.dig("result", "range", "start", "character")

      assert_equal uri, type_definition.dig("result", "uri")
      assert_equal 0, type_definition.dig("result", "range", "start", "line")
      assert_equal 9, type_definition.dig("result", "range", "start", "character")
    end
  end

  def test_definition_falls_back_to_other_workspace_file
    Dir.mktmpdir("milk-tea-lsp-def") do |dir|
      shared_path = File.join(dir, "shared.mt")
      main_path = File.join(dir, "main.mt")
      File.write(shared_path, <<~MT)
        function shared(a: int, b: int) -> int:
            return a + b
      MT
      File.write(main_path, <<~MT)
        function main() -> int:
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
        assert_equal 9, definition.dig("result", "range", "start", "character")
      end
    end
  end

  def test_definition_on_imported_module_member_jumps_to_member_declaration
    Dir.mktmpdir("milk-tea-lsp-def-member") do |dir|
      lib_path = File.join(dir, "demo", "lib.mt")
      main_path = File.join(dir, "main.mt")
      Dir.mkdir(File.join(dir, "demo"))

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

        definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })
        definition_line = lib_source.lines.index { |line| line.include?("function greet") }
        definition_char = lib_source.lines.fetch(definition_line).index("greet")

        assert_equal lib_uri, definition.dig("result", "uri")
        assert_equal definition_line, definition.dig("result", "range", "start", "line")
        assert_equal definition_char, definition.dig("result", "range", "start", "character")
      end
    end
  end

  def test_definition_on_imported_module_member_refreshes_when_closed_file_changes_within_same_second
    Dir.mktmpdir("milk-tea-lsp-def-member-mtime") do |dir|
      lib_path = File.join(dir, "demo", "lib.mt")
      main_path = File.join(dir, "main.mt")
      FileUtils.mkdir_p(File.join(dir, "demo"))

      initial_lib_source = <<~MT
        function greet() -> int:
            return 1
      MT
      updated_lib_source = <<~MT
        # shifted on purpose
        function greet() -> int:
            return 1
      MT
      main_source = <<~MT
        import demo.lib as lib

        function main() -> int:
            return lib.greet()
      MT

      File.write(lib_path, initial_lib_source)
      File.write(main_path, main_source)

      first_time = Time.at(Time.now.to_i, 100_000_000, :nsec)
      second_time = Time.at(first_time.to_i, 700_000_000, :nsec)
      File.utime(first_time, first_time, lib_path)

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

        first_definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        assert_equal lib_uri, first_definition.dig("result", "uri")
        assert_equal 0, first_definition.dig("result", "range", "start", "line")

        File.write(lib_path, updated_lib_source)
        File.utime(second_time, second_time, lib_path)

        second_definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        assert_equal lib_uri, second_definition.dig("result", "uri")
        assert_equal 1, second_definition.dig("result", "range", "start", "line")
      end
    end
  end

  def test_definition_on_imported_type_static_method_jumps_to_method_declaration
    Dir.mktmpdir("milk-tea-lsp-def-imported-type") do |dir|
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
        definition_char = foo_source.lines[definition_line].index("zero")

        definition = client.send_request("textDocument/definition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        assert_equal foo_uri, definition.dig("result", "uri")
        assert_equal definition_line, definition.dig("result", "range", "start", "line")
        assert_equal definition_char, definition.dig("result", "range", "start", "character")
      end
    end
  end

  def test_type_definition_on_imported_type_static_method_jumps_to_method_declaration
    Dir.mktmpdir("milk-tea-lsp-type-def-imported-type") do |dir|
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
        definition_char = foo_source.lines[definition_line].index("zero")

        definition = client.send_request("textDocument/typeDefinition", {
          "textDocument" => { "uri" => main_uri },
          "position" => { "line" => call_line, "character" => call_char }
        })

        assert_equal foo_uri, definition.dig("result", "uri")
        assert_equal definition_line, definition.dig("result", "range", "start", "line")
        assert_equal definition_char, definition.dig("result", "range", "start", "character")
      end
    end
  end

  def test_definition_returns_field_declaration_for_member_access_segments
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_member_chain_definition_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_MEMBER_CHAIN_HOVER }
      })

      definition = client.send_request("textDocument/definition", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 8, "character" => 27 }
      })
      definition_result = definition.fetch("result")

      assert_equal uri, definition_result.fetch("uri")
      assert_equal 1, definition_result.dig("range", "start", "line")
    end
  end

  def test_definition_returns_current_module_field_declaration_in_tetris
    with_server do |client|
      client.send_request("initialize", { "rootUri" => path_to_uri(Dir.pwd), "capabilities" => {} })
      client.send_notification("initialized", {})

      source_path = File.expand_path("projects/tetris/src/main.mt", Dir.pwd)
      uri = path_to_uri(source_path)
      source = File.read(source_path)
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      line = source.lines.index { |text| text.include?("this.drop_timer +=") }
      character = source.lines.fetch(line).index("drop_timer")
      definition = client.send_request("textDocument/definition", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => line, "character" => character }
      })
      definition_result = definition.fetch("result")

      expected_line = source.lines.index { |text| text == "    drop_timer: float\n" }
      assert_equal uri, definition_result.fetch("uri")
      assert_equal expected_line, definition_result.dig("range", "start", "line")
    end
  end

end
