# frozen_string_literal: true

require_relative "helpers"

class RenameTest < Minitest::Test
  include LSPServerTestHelpers

  def test_prepare_rename_returns_range_and_placeholder
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_prep_rename_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      response = client.send_request("textDocument/prepareRename", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 0, "character" => 9 }
      })
      result = response.fetch("result")
      assert_equal "add", result["placeholder"]
      assert_equal 0, result.dig("range", "start", "line")
      assert_equal 9, result.dig("range", "start", "character")
    end
  end

  def test_rename_produces_workspace_edit_for_all_occurrences
    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_rename_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => SOURCE_WITH_CALL }
      })
      response = client.send_request("textDocument/rename", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 0, "character" => 9 },
        "newName"      => "sum"
      })
      changes = response.dig("result", "changes", uri)
      assert_kind_of Array, changes
      assert changes.length >= 2, "expected at least 2 edits for 'add' rename, got #{changes.length}"
      changes.each { |edit| assert_equal "sum", edit["newText"] }
    end
  end

  def test_rename_local_variable_is_scoped_under_shadowing
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
      uri = "file:///tmp/lsp_rename_shadowed_local.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      # Rename the inner `value` declaration inside the if block.
      response = client.send_request("textDocument/rename", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 4, "character" => 12 },
        "newName"      => "inner_value"
      })

      changes = response.dig("result", "changes", uri)
      assert_kind_of Array, changes
      assert_equal 2, changes.length

      starts = changes.map { |edit| [edit.dig("range", "start", "line"), edit.dig("range", "start", "character")] }
      assert_includes starts, [4, 12]
      assert_includes starts, [5, 16]
      changes.each { |edit| assert_equal "inner_value", edit["newText"] }
    end
  end

  def test_rename_local_variable_from_usage_is_scoped_under_shadowing
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
      uri = "file:///tmp/lsp_rename_shadowed_local_usage.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      # Rename from the inner usage `value` in `let b = value`.
      response = client.send_request("textDocument/rename", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 5, "character" => 17 },
        "newName"      => "inner_value"
      })

      changes = response.dig("result", "changes", uri)
      assert_kind_of Array, changes
      assert_equal 2, changes.length

      starts = changes.map { |edit| [edit.dig("range", "start", "line"), edit.dig("range", "start", "character")] }
      assert_includes starts, [4, 12]
      assert_includes starts, [5, 16]
      changes.each { |edit| assert_equal "inner_value", edit["newText"] }
    end
  end

  def test_rename_import_alias_renames_declaration_and_usages
    Dir.mktmpdir("milk-tea-lsp-rename-import-alias") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      util_source = <<~MT
        public struct Point:
            x: int
            y: int
      MT
      main_source = <<~MT
        import std.util as util

        function make() -> util.Point:
            return util.Point(x = 1, y = 2)
      MT

      File.write(File.join(std_dir, "util.mt"), util_source)
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

        # Rename from the alias declaration site: `import std.util as util` (line 0, "util" at col 20)
        alias_line  = 0
        alias_char  = main_source.lines[alias_line].index(" util") + 1

        response = client.send_request("textDocument/rename", {
          "textDocument" => { "uri" => main_uri },
          "position"     => { "line" => alias_line, "character" => alias_char },
          "newName"      => "u"
        })

        changes = response.dig("result", "changes", main_uri)
        assert_kind_of Array, changes, "expected rename edits for import alias"
        # Expect: 1 declaration + 2 usages (util.Point return type, util.Point constructor)
        assert_equal 3, changes.length, "expected 3 edits (declaration + 2 qualifier usages), got #{changes.length}"
        changes.each { |edit| assert_equal "u", edit["newText"] }

        new_texts = changes.map { |e| e["newText"] }
        assert new_texts.all? { |t| t == "u" }
      end
    end
  end

  def test_rename_import_alias_from_usage_site_renames_declaration_and_all_usages
    Dir.mktmpdir("milk-tea-lsp-rename-import-alias-usage") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      util_source = <<~MT
        public struct Point:
            x: int
            y: int
      MT
      main_source = <<~MT
        import std.util as util

        function make() -> util.Point:
            return util.Point(x = 1, y = 2)
      MT

      File.write(File.join(std_dir, "util.mt"), util_source)
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

        # Rename from a usage site: `util.Point` on line 2 (0-based)
        usage_line = 2
        usage_char = main_source.lines[usage_line].index("util.") + 1

        response = client.send_request("textDocument/rename", {
          "textDocument" => { "uri" => main_uri },
          "position"     => { "line" => usage_line, "character" => usage_char },
          "newName"      => "u"
        })

        changes = response.dig("result", "changes", main_uri)
        assert_kind_of Array, changes, "expected rename edits when renaming from usage"
        assert_equal 3, changes.length, "expected 3 edits (declaration + 2 qualifier usages), got #{changes.length}"
        changes.each { |edit| assert_equal "u", edit["newText"] }
      end
    end
  end

  def test_rename_enum_member_renames_declaration_and_member_access_with_semantic_stability
    source = <<~MT
      public enum Scene: ubyte
          menu = 0
          lobby = 1
          game = 2

      function current() -> Scene:
          return Scene.lobby
    MT

    with_server do |client|
      init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")

      uri = "file:///tmp/lsp_rename_enum_member.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/rename", {
        "textDocument" => { "uri" => uri },
        "position" => { "line" => 2, "character" => 4 },
        "newName" => "lounge"
      })

      changes = response.dig("result", "changes", uri)
      assert_kind_of Array, changes
      assert_equal 2, changes.length
      changes.each { |edit| assert_equal "lounge", edit["newText"] }

      updated = apply_workspace_edits_to_source(source, changes)
      client.send_notification("textDocument/didChange", {
        "textDocument" => { "uri" => uri, "version" => 2 },
        "contentChanges" => [{ "text" => updated }]
      })

      semantic = client.send_request("textDocument/semanticTokens/full", {
        "textDocument" => { "uri" => uri }
      })
      entries = decode_semantic_token_entries(semantic.fetch("result").fetch("data"), legend)

      decl_entry = semantic_entry_for_lexeme_on_line(updated, entries, "lounge", 2)
      use_entry = semantic_entry_for_lexeme_on_line(updated, entries, "lounge", 6)

      assert_equal "enumMember", decl_entry.fetch("tokenType")
      assert_includes decl_entry.fetch("modifierNames"), "declaration"
      assert_equal "enumMember", use_entry.fetch("tokenType")
    end
  end

  def test_rename_workspace_symbol_identity_updates_related_modules_only
    Dir.mktmpdir("milk-tea-lsp-rename-workspace-identity") do |dir|
      api_path = File.join(dir, "api.mt")
      consumer_path = File.join(dir, "consumer.mt")
      unrelated_path = File.join(dir, "unrelated.mt")

      api_source = <<~MT
        public function ping() -> int:
            return 1
      MT
      consumer_source = <<~MT
        import api as api

        function run() -> int:
            return api.ping()
      MT
      unrelated_source = <<~MT
        function ping() -> int:
            return 99
      MT

      File.write(api_path, api_source)
      File.write(consumer_path, consumer_source)
      File.write(unrelated_path, unrelated_source)

      root_uri = path_to_uri(dir)
      api_uri = path_to_uri(api_path)
      consumer_uri = path_to_uri(consumer_path)
      unrelated_uri = path_to_uri(unrelated_path)

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")
        client.send_notification("initialized", {})

        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => api_uri, "languageId" => "milk-tea", "version" => 1, "text" => api_source }
        })
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => consumer_uri, "languageId" => "milk-tea", "version" => 1, "text" => consumer_source }
        })
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => unrelated_uri, "languageId" => "milk-tea", "version" => 1, "text" => unrelated_source }
        })

        response = client.send_request("textDocument/rename", {
          "textDocument" => { "uri" => api_uri },
          "position" => { "line" => 0, "character" => 16 },
          "newName" => "pong"
        })

        changes = response.dig("result", "changes")
        assert_kind_of Hash, changes
        assert_includes changes.keys, api_uri
        assert_includes changes.keys, consumer_uri
        refute_includes changes.keys, unrelated_uri

        api_updated = apply_workspace_edits_to_source(api_source, changes.fetch(api_uri))
        consumer_updated = apply_workspace_edits_to_source(consumer_source, changes.fetch(consumer_uri))

        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => api_uri, "version" => 2 },
          "contentChanges" => [{ "text" => api_updated }]
        })
        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => consumer_uri, "version" => 2 },
          "contentChanges" => [{ "text" => consumer_updated }]
        })

        api_semantic = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => api_uri }
        })
        consumer_semantic = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => consumer_uri }
        })
        unrelated_semantic = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => unrelated_uri }
        })

        api_entries = decode_semantic_token_entries(api_semantic.fetch("result").fetch("data"), legend)
        consumer_entries = decode_semantic_token_entries(consumer_semantic.fetch("result").fetch("data"), legend)
        unrelated_entries = decode_semantic_token_entries(unrelated_semantic.fetch("result").fetch("data"), legend)

        api_decl = semantic_entry_for_lexeme(api_updated, api_entries, "pong")
        consumer_call = semantic_entry_for_lexeme(consumer_updated, consumer_entries, "pong")
        unrelated_ping = semantic_entry_for_lexeme(unrelated_source, unrelated_entries, "ping")

        assert_equal "function", api_decl.fetch("tokenType")
        assert_equal "method", consumer_call.fetch("tokenType")
        assert_equal "function", unrelated_ping.fetch("tokenType")
      end
    end
  end

  def test_rename_local_includes_fstring_interpolation
    source = <<~'MT'
      function main() -> int:
          let value = 42
          let msg = f"result #{value} and #{value + 1}"
          return value
    MT

    with_shared_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_rename_fstring_test.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/rename", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => 1, "character" => 8 },
        "newName"      => "count"
      })

      changes = response.dig("result", "changes", uri)
      assert_kind_of Array, changes
      assert_equal 4, changes.length, "expected 4 edits (decl + usage + 2 interpolation refs), got #{changes.length}"

      starts = changes.map { |edit| [edit.dig("range", "start", "line"), edit.dig("range", "start", "character")] }
      assert_includes starts, [1, 8], "missing declaration edit"
      assert_includes starts, [3, 11], "missing return usage edit"
      assert_includes starts, [2, 25], "missing first interpolation edit"
      assert_includes starts, [2, 38], "missing second interpolation edit"
      changes.each { |edit| assert_equal "count", edit["newText"] }
    end
  end

  def test_rename_matrix_updates_semantic_tokens_for_common_symbol_kinds
    cases = [
      {
        name: "free-function",
        source: <<~MT,
          function add_value(a: int) -> int:
              return a

          function main() -> int:
              return add_value(1)
        MT
        rename_position: { line: 0, character: 9 },
        new_name: "sum_value",
        semantic_checks: [
          { lexeme: "sum_value", token_type: "function" }
        ],
      },
      {
        name: "local-variable",
        source: <<~MT,
          function main() -> int:
              let local_value = 1
              return local_value
        MT
        rename_position: { line: 1, character: 8 },
        new_name: "value_local",
        semantic_checks: [
          { lexeme: "value_local", token_type: "variable" }
        ],
      },
      {
        name: "parameter",
        source: <<~MT,
          function main(param_value: int) -> int:
              return param_value
        MT
        rename_position: { line: 0, character: 14 },
        new_name: "input_value",
        semantic_checks: [
          { lexeme: "input_value", token_type: "parameter" }
        ],
      },
      {
        name: "struct-type",
        source: <<~MT,
          struct PointType:
              x: int

          function make() -> PointType:
              return PointType(x = 1)
        MT
        rename_position: { line: 0, character: 7 },
        new_name: "Vector2",
        semantic_checks: [
          { lexeme: "Vector2", token_type: "type" }
        ],
      },
      {
        name: "const",
        source: <<~MT,
          const MAX_COUNT: int = 3

          function main() -> int:
              return MAX_COUNT
        MT
        rename_position: { line: 0, character: 6 },
        new_name: "LIMIT_COUNT",
        semantic_checks: [
          { lexeme: "LIMIT_COUNT", token_type: "variable" }
        ],
      },
      {
        name: "global-var",
        source: <<~MT,
          var global_counter: int = 0

          function main() -> int:
              return global_counter
        MT
        rename_position: { line: 0, character: 4 },
        new_name: "counter_global",
        semantic_checks: [
          { lexeme: "counter_global", token_type: "variable" }
        ],
      },
      {
        name: "for-binding",
        source: <<~MT,
          function sum(values: span[int]) -> int:
              var total = 0
              for item in values:
                  total += item
              return total
        MT
        rename_position: { line: 2, character: 8 },
        new_name: "entry",
        semantic_checks: [
          { lexeme: "entry", token_type: "variable" }
        ],
      },
      {
        name: "match-binding",
        source: <<~MT,
          function unwrap(value: Option[int]) -> int:
              match value:
                  Option.some as payload:
                      return payload
                  Option.none:
                      return 0
        MT
        rename_position: { line: 2, character: 23 },
        new_name: "inner_value",
        semantic_checks: [
          { lexeme: "inner_value", token_type: "variable" }
        ],
      },
    ]

    with_server do |client|
      init = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")

      cases.each_with_index do |test_case, index|
        uri = "file:///tmp/lsp_rename_semantic_matrix_#{index}.mt"
        source = test_case.fetch(:source)

        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        rename_response = client.send_request("textDocument/rename", {
          "textDocument" => { "uri" => uri },
          "position" => test_case.fetch(:rename_position),
          "newName" => test_case.fetch(:new_name)
        })

        changes = rename_response.dig("result", "changes", uri)
        assert_kind_of Array, changes, "#{test_case.fetch(:name)}: expected workspace edits"
        refute_empty changes, "#{test_case.fetch(:name)}: expected at least one edit"

        updated_source = apply_workspace_edits_to_source(source, changes)
        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => uri, "version" => 2 },
          "contentChanges" => [{ "text" => updated_source }]
        })

        semantic = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => uri }
        })
        entries = decode_semantic_token_entries(semantic.fetch("result").fetch("data"), legend)

        test_case.fetch(:semantic_checks).each do |check|
          entry = semantic_entry_for_lexeme(updated_source, entries, check.fetch(:lexeme))
          assert_equal check.fetch(:token_type), entry.fetch("tokenType"),
                       "#{test_case.fetch(:name)}: expected '#{check.fetch(:lexeme)}' to be #{check.fetch(:token_type)}"
        end

        client.send_notification("textDocument/didClose", {
          "textDocument" => { "uri" => uri }
        })
      end
    end
  end

  def test_cross_file_rename_matrix_scoping_and_semantic_stability
    Dir.mktmpdir("milk-tea-lsp-cross-file-rename-matrix") do |dir|
      root_uri = path_to_uri(dir)

      with_server do |client|
        init = client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        legend = init.dig("result", "capabilities", "semanticTokensProvider", "legend")

        # Case 1: Same-name collisions across files should not be cross-renamed.
        coll_a_path = File.join(dir, "collision_a.mt")
        coll_b_path = File.join(dir, "collision_b.mt")
        coll_a_source = <<~MT
          function ping() -> int:
              return 1

          function call_a() -> int:
              return ping()
        MT
        coll_b_source = <<~MT
          function ping() -> int:
              return 2

          function call_b() -> int:
              return ping()
        MT
        File.write(coll_a_path, coll_a_source)
        File.write(coll_b_path, coll_b_source)

        coll_a_uri = path_to_uri(coll_a_path)
        coll_b_uri = path_to_uri(coll_b_path)

        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => coll_a_uri, "languageId" => "milk-tea", "version" => 1, "text" => coll_a_source }
        })
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => coll_b_uri, "languageId" => "milk-tea", "version" => 1, "text" => coll_b_source }
        })

        coll_rename = client.send_request("textDocument/rename", {
          "textDocument" => { "uri" => coll_a_uri },
          "position" => { "line" => 0, "character" => 9 },
          "newName" => "alpha_ping"
        })
        coll_changes = coll_rename.dig("result", "changes") || {}

        assert_includes coll_changes.keys, coll_a_uri
        refute_includes coll_changes.keys, coll_b_uri

        coll_a_updated = apply_workspace_edits_to_source(coll_a_source, coll_changes.fetch(coll_a_uri))
        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => coll_a_uri, "version" => 2 },
          "contentChanges" => [{ "text" => coll_a_updated }]
        })

        coll_a_semantic = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => coll_a_uri }
        })
        coll_b_semantic = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => coll_b_uri }
        })

        coll_a_entries = decode_semantic_token_entries(coll_a_semantic.fetch("result").fetch("data"), legend)
        coll_b_entries = decode_semantic_token_entries(coll_b_semantic.fetch("result").fetch("data"), legend)

        coll_a_renamed = semantic_entry_for_lexeme(coll_a_updated, coll_a_entries, "alpha_ping")
        assert_equal "function", coll_a_renamed.fetch("tokenType")

        coll_b_ping = semantic_entry_for_lexeme(coll_b_source, coll_b_entries, "ping")
        assert_equal "function", coll_b_ping.fetch("tokenType")
        refute coll_changes.fetch(coll_a_uri).any? { |edit| edit.fetch("newText") == "ping" }

        # Case 2: Import alias rename is scoped to the current file.
        std_dir = File.join(dir, "std")
        FileUtils.mkdir_p(std_dir)
        shared_path = File.join(std_dir, "shared.mt")
        File.write(shared_path, <<~MT)
          public struct Point:
              x: int

          extending Point:
              public static function zero() -> int:
                  return 0
        MT

        import_a_path = File.join(dir, "import_a.mt")
        import_b_path = File.join(dir, "import_b.mt")
        import_a_source = <<~MT
          import std.shared as util

          function main_a() -> int:
              return util.Point.zero()
        MT
        import_b_source = <<~MT
          import std.shared as util

          function main_b() -> int:
              return util.Point.zero()
        MT
        File.write(import_a_path, import_a_source)
        File.write(import_b_path, import_b_source)

        import_a_uri = path_to_uri(import_a_path)
        import_b_uri = path_to_uri(import_b_path)

        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => import_a_uri, "languageId" => "milk-tea", "version" => 1, "text" => import_a_source }
        })
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => import_b_uri, "languageId" => "milk-tea", "version" => 1, "text" => import_b_source }
        })

        alias_char = import_a_source.lines[0].rindex("util")
        alias_rename = client.send_request("textDocument/rename", {
          "textDocument" => { "uri" => import_a_uri },
          "position" => { "line" => 0, "character" => alias_char },
          "newName" => "fx"
        })
        alias_changes = alias_rename.dig("result", "changes") || {}

        assert_includes alias_changes.keys, import_a_uri
        refute_includes alias_changes.keys, import_b_uri

        import_a_updated = apply_workspace_edits_to_source(import_a_source, alias_changes.fetch(import_a_uri))
        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => import_a_uri, "version" => 2 },
          "contentChanges" => [{ "text" => import_a_updated }]
        })

        import_a_semantic = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => import_a_uri }
        })
        import_b_semantic = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => import_b_uri }
        })

        import_a_entries = decode_semantic_token_entries(import_a_semantic.fetch("result").fetch("data"), legend)
        import_b_entries = decode_semantic_token_entries(import_b_semantic.fetch("result").fetch("data"), legend)

        import_a_alias = semantic_entry_for_lexeme(import_a_updated, import_a_entries, "fx")
        import_b_alias = semantic_entry_for_lexeme(import_b_source, import_b_entries, "util")

        assert_equal "namespace", import_a_alias.fetch("tokenType")
        assert_equal "namespace", import_b_alias.fetch("tokenType")

        # Case 3: Renaming in a dependency should keep semantic classification stable
        # for already-open dependent documents.
        api_path = File.join(dir, "api.mt")
        dep_a_path = File.join(dir, "dep_a.mt")
        dep_b_path = File.join(dir, "dep_b.mt")

        api_source = <<~MT
          public type StatusCode = int

          function local_helper(value: int) -> int:
              return value
        MT
        dep_a_source = <<~MT
          import api as api

          function read_a(value: api.StatusCode) -> api.StatusCode:
              return value
        MT
        dep_b_source = <<~MT
          import api as api

          function read_b(value: api.StatusCode) -> api.StatusCode:
              return value
        MT
        File.write(api_path, api_source)
        File.write(dep_a_path, dep_a_source)
        File.write(dep_b_path, dep_b_source)

        api_uri = path_to_uri(api_path)
        dep_a_uri = path_to_uri(dep_a_path)
        dep_b_uri = path_to_uri(dep_b_path)

        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => api_uri, "languageId" => "milk-tea", "version" => 1, "text" => api_source }
        })
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => dep_a_uri, "languageId" => "milk-tea", "version" => 1, "text" => dep_a_source }
        })
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => dep_b_uri, "languageId" => "milk-tea", "version" => 1, "text" => dep_b_source }
        })

        dep_rename = client.send_request("textDocument/rename", {
          "textDocument" => { "uri" => api_uri },
          "position" => { "line" => 2, "character" => 11 },
          "newName" => "renamed_helper"
        })
        dep_changes = dep_rename.dig("result", "changes") || {}

        assert_includes dep_changes.keys, api_uri
        refute_includes dep_changes.keys, dep_a_uri
        refute_includes dep_changes.keys, dep_b_uri

        api_updated = apply_workspace_edits_to_source(api_source, dep_changes.fetch(api_uri))
        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => api_uri, "version" => 2 },
          "contentChanges" => [{ "text" => api_updated }]
        })

        dep_a_semantic = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => dep_a_uri }
        })
        dep_b_semantic = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => dep_b_uri }
        })

        dep_a_entries = decode_semantic_token_entries(dep_a_semantic.fetch("result").fetch("data"), legend)
        dep_b_entries = decode_semantic_token_entries(dep_b_semantic.fetch("result").fetch("data"), legend)

        dep_a_ns = semantic_entry_for_lexeme(dep_a_source, dep_a_entries, "api")
        dep_a_type = semantic_entry_for_lexeme(dep_a_source, dep_a_entries, "StatusCode")
        dep_b_ns = semantic_entry_for_lexeme(dep_b_source, dep_b_entries, "api")
        dep_b_type = semantic_entry_for_lexeme(dep_b_source, dep_b_entries, "StatusCode")

        assert_equal "namespace", dep_a_ns.fetch("tokenType")
        assert_equal "type", dep_a_type.fetch("tokenType")
        assert_equal "namespace", dep_b_ns.fetch("tokenType")
        assert_equal "type", dep_b_type.fetch("tokenType")

        # Case 4: Identical method names across unrelated receiver types in
        # separate files must stay scoped under rename.
        method_a_path = File.join(dir, "method_a.mt")
        method_b_path = File.join(dir, "method_b.mt")
        caller_a_path = File.join(dir, "caller_a.mt")
        caller_b_path = File.join(dir, "caller_b.mt")

        method_a_source = <<~MT
          public struct Alpha:
              value: int

          extending Alpha:
              public static function tick() -> int:
                  return 1

          function call_a() -> int:
              return Alpha.tick()
        MT
        method_b_source = <<~MT
          public struct Beta:
              value: int

          extending Beta:
              public static function tick() -> int:
                  return 2

          function call_b() -> int:
              return Beta.tick()
        MT
        caller_a_source = <<~MT
          import method_a as ma

          function run_a() -> int:
              return ma.Alpha.tick()
        MT
        caller_b_source = <<~MT
          import method_b as mb

          function run_b() -> int:
              return mb.Beta.tick()
        MT

        File.write(method_a_path, method_a_source)
        File.write(method_b_path, method_b_source)
        File.write(caller_a_path, caller_a_source)
        File.write(caller_b_path, caller_b_source)

        method_a_uri = path_to_uri(method_a_path)
        method_b_uri = path_to_uri(method_b_path)
        caller_a_uri = path_to_uri(caller_a_path)
        caller_b_uri = path_to_uri(caller_b_path)

        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => method_a_uri, "languageId" => "milk-tea", "version" => 1, "text" => method_a_source }
        })
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => method_b_uri, "languageId" => "milk-tea", "version" => 1, "text" => method_b_source }
        })
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => caller_a_uri, "languageId" => "milk-tea", "version" => 1, "text" => caller_a_source }
        })
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => caller_b_uri, "languageId" => "milk-tea", "version" => 1, "text" => caller_b_source }
        })

        method_decl_line = method_a_source.lines.index { |line| line.include?("function tick") }
        method_decl_char = method_a_source.lines[method_decl_line].index("tick")
        method_rename = client.send_request("textDocument/rename", {
          "textDocument" => { "uri" => method_a_uri },
          "position" => { "line" => method_decl_line, "character" => method_decl_char },
          "newName" => "pulse"
        })
        method_changes = method_rename.dig("result", "changes") || {}

        assert_includes method_changes.keys, method_a_uri
        refute_includes method_changes.keys, method_b_uri
        refute_includes method_changes.keys, caller_b_uri

        method_a_updated = apply_workspace_edits_to_source(method_a_source, method_changes.fetch(method_a_uri))
        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => method_a_uri, "version" => 2 },
          "contentChanges" => [{ "text" => method_a_updated }]
        })

        method_a_semantic = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => method_a_uri }
        })
        method_b_semantic = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => method_b_uri }
        })
        caller_b_semantic = client.send_request("textDocument/semanticTokens/full", {
          "textDocument" => { "uri" => caller_b_uri }
        })

        method_a_entries = decode_semantic_token_entries(method_a_semantic.fetch("result").fetch("data"), legend)
        method_b_entries = decode_semantic_token_entries(method_b_semantic.fetch("result").fetch("data"), legend)
        caller_b_entries = decode_semantic_token_entries(caller_b_semantic.fetch("result").fetch("data"), legend)

        method_a_pulse = semantic_entry_for_lexeme(method_a_updated, method_a_entries, "pulse")
        method_b_tick = semantic_entry_for_lexeme(method_b_source, method_b_entries, "tick")
        caller_b_tick = semantic_entry_for_lexeme(caller_b_source, caller_b_entries, "tick")

        assert_equal "function", method_a_pulse.fetch("tokenType")
        assert_equal "function", method_b_tick.fetch("tokenType")
        assert_equal "method", caller_b_tick.fetch("tokenType")
      end
    end
  end

end
