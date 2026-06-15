# frozen_string_literal: true

require_relative "helpers"

class NestedStructAuditTest < Minitest::Test
  include LSPServerTestHelpers

  NESTED_STRUCT_SOURCE = <<~MT
    struct Rectangle:
        x: float
        y: float

        struct Edge:
            start: float
            end: float

        top_edge: Edge
        left_edge: Edge
        width: float
        height: float

    function basic_nested_demo() -> float:
        var r: Rectangle
        r.x = 1.0
        r.width = 10.0
        r.top_edge.start = 3.0
        return r.x + r.width + r.top_edge.start

    struct Level1:
        data: int

        struct Level2:
            tag: int

            struct Level3:
                value: float

            inner: Level3

        mid: Level2

    function deeply_nested_demo() -> float:
        var l1: Level1
        l1.data = 1
        l1.mid.tag = 2
        l1.mid.inner.value = 3.0
        return float<-(l1.data) + float<-(l1.mid.tag) + l1.mid.inner.value

    function param_nested_demo() -> float:
        var edge: Rectangle.Edge
        edge.start = 0.0
        edge.end = 1.0
        return edge.start + edge.end

    extending Rectangle.Edge:
        function length() -> float:
            return this.end - this.start

    function extend_nested_demo() -> float:
        var e: Rectangle.Edge
        e.start = 0.0
        e.end = 10.0
        return e.length()
  MT

  VALID_EXTENSION = <<~MT

    function main() -> int:
        return 0
  MT

  FULL_SOURCE = NESTED_STRUCT_SOURCE + VALID_EXTENSION

  # =====================================================================
  # RENAME TESTS
  # =====================================================================

  def test_rename_nested_struct_field_start
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_audit_rename_nested_field.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
      })

      start_line = NESTED_STRUCT_SOURCE.lines.index { |l| l.match?(/start:\s+float/) }
      start_char = NESTED_STRUCT_SOURCE.lines[start_line].index("start")

      response = client.send_request("textDocument/rename", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => start_line, "character" => start_char },
        "newName"      => "from"
      })

      changes = response.dig("result", "changes", uri)
      assert_kind_of Array, changes
      assert changes.length >= 6, "expected >= 6 edits, got #{changes.length}"
      changes.each { |edit| assert_equal "from", edit["newText"] }

      updated = apply_workspace_edits_to_source(FULL_SOURCE, changes)
      assert updated.include?("from: float")
      refute updated.include?("start: float")
      refute updated.include?("r.top_edge.start")
      assert updated.include?("r.top_edge.from")
      refute updated.include?("edge.start")
      assert updated.include?("edge.from")
      refute updated.include?("e.start")
      assert updated.include?("e.from")
      refute updated.include?("this.end - this.start")
      assert updated.include?("this.end - this.from")
    end
  end

  def test_rename_nested_struct_field_end
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_audit_rename_end.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
      })

      end_line = NESTED_STRUCT_SOURCE.lines.index { |l| l.match?(/end:\s+float/) }
      end_char = NESTED_STRUCT_SOURCE.lines[end_line].index("end")

      response = client.send_request("textDocument/rename", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => end_line, "character" => end_char },
        "newName"      => "stop"
      })

      changes = response.dig("result", "changes", uri)
      assert_kind_of Array, changes
      assert changes.length >= 3, "expected >= 3 edits, got #{changes.length}"
      changes.each { |edit| assert_equal "stop", edit["newText"] }

      updated = apply_workspace_edits_to_source(FULL_SOURCE, changes)
      assert updated.include?("stop: float")
      refute updated.include?("edge.end")
      assert updated.include?("edge.stop")
      refute updated.include?("this.end")
      assert updated.include?("this.stop")
    end
  end

  def test_rename_deeply_nested_struct_field
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_audit_rename_deeply_field.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
      })

      value_line = NESTED_STRUCT_SOURCE.lines.index { |l| l.match?(/value:\s+float/) }
      value_char = NESTED_STRUCT_SOURCE.lines[value_line].index("value")

      response = client.send_request("textDocument/rename", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => value_line, "character" => value_char },
        "newName"      => "amount"
      })

      changes = response.dig("result", "changes", uri)
      assert_kind_of Array, changes
      assert changes.length >= 3, "expected >= 3 edits, got #{changes.length}"
      changes.each { |edit| assert_equal "amount", edit["newText"] }

      updated = apply_workspace_edits_to_source(FULL_SOURCE, changes)
      assert updated.include?("amount: float")
      refute updated.include?("value: float")
      refute updated.include?("l1.mid.inner.value")
      assert updated.include?("l1.mid.inner.amount")
    end
  end

  def test_rename_nested_field_from_usage_site
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_audit_rename_qualified_field.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
      })

      line = NESTED_STRUCT_SOURCE.lines.index { |l| l.include?("edge.start = 0.0") }
      char = NESTED_STRUCT_SOURCE.lines[line].index("start")

      response = client.send_request("textDocument/rename", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => line, "character" => char },
        "newName"      => "from"
      })

      changes = response.dig("result", "changes", uri)
      assert_kind_of Array, changes
      assert changes.length >= 6, "expected >= 6 edits from usage site, got #{changes.length}"
      changes.each { |edit| assert_equal "from", edit["newText"] }
    end
  end

  def test_rename_struct_field_on_parent_with_nested_types
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_audit_rename_parent_field.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
      })

      line = NESTED_STRUCT_SOURCE.lines.index { |l| l.match?(/top_edge:\s+Edge/) }
      char = NESTED_STRUCT_SOURCE.lines[line].index("top_edge")

      response = client.send_request("textDocument/rename", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => line, "character" => char },
        "newName"      => "upper_edge"
      })

      changes = response.dig("result", "changes", uri)
      assert_kind_of Array, changes
      assert changes.length >= 2, "expected >= 2 edits, got #{changes.length}"
      changes.each { |edit| assert_equal "upper_edge", edit["newText"] }

      updated = apply_workspace_edits_to_source(FULL_SOURCE, changes)
      assert updated.include?("upper_edge: Edge")
      assert updated.include?("r.upper_edge.start")
    end
  end

  def test_rename_extending_method_on_nested_type
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_audit_rename_nested_method.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
      })

      length_line = NESTED_STRUCT_SOURCE.lines.index { |l| l.strip == "function length() -> float:" }
      length_char = NESTED_STRUCT_SOURCE.lines[length_line].index("length")

      response = client.send_request("textDocument/rename", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => length_line, "character" => length_char },
        "newName"      => "span"
      })

      changes = response.dig("result", "changes", uri)
      assert_kind_of Array, changes
      assert changes.length >= 2, "expected >= 2 edits, got #{changes.length}"
      changes.each { |edit| assert_equal "span", edit["newText"] }

      updated = apply_workspace_edits_to_source(FULL_SOURCE, changes)
      assert updated.include?("function span() -> float:")
      assert updated.include?("return e.span()")
      refute updated.include?("e.length()")
    end
  end

  def test_prepare_rename_nested_struct_field
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_audit_prep_rename.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
      })

      end_line = NESTED_STRUCT_SOURCE.lines.index { |l| l.match?(/end:\s+float/) }
      end_char = NESTED_STRUCT_SOURCE.lines[end_line].index("end")

      response = client.send_request("textDocument/prepareRename", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => end_line, "character" => end_char }
      })

      result = response.fetch("result")
      assert_equal "end", result["placeholder"]
      assert_equal end_line, result.dig("range", "start", "line")
    end
  end

  # =====================================================================
  # COMPLETION TESTS
  #
  # Each test replaces a return statement in an EXISTING function (not a
  # new one) so the server can use last-good facts to resolve the local
  # variable type.  The helper writes FULL_SOURCE to disk, opens it,
  # then sends a didChange that substitutes a return line with a dot
  # completion stub.
  # =====================================================================

  # Replace the return line in a given function with the completion stub.
  # Returns the partial source after substitution and the 0-based line/char
  # of the dot position for the completion request.
  def make_completion_stub(source, function_name, stub_line)
    fn_start = source.lines.index { |l| l.include?("function #{function_name}(") }
    raise "function #{function_name} not found" unless fn_start

    return_idx = (fn_start + 1..source.lines.length - 1).find { |i|
      source.lines[i]&.match?(/^\s+return\s/)
    }
    raise "no return in #{function_name}" unless return_idx

    lines = source.lines.dup
    lines[return_idx] = stub_line
    partial = lines.join
    # The stub line is at the same index as the original return.
    dot_line = return_idx
    dot_char = stub_line.chomp.length
    [partial, dot_line, dot_char]
  end

  # Run the standard open-valid-then-change-to-partial completion test.
  def with_completion_test(source:, function:, stub:, expected:, label: "dot completion")
    Dir.mktmpdir("mt-lsp-audit-comp") do |dir|
      path = File.join(dir, "main.mt")
      File.write(path, source)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)

        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        partial, dot_line, dot_char = make_completion_stub(source, function, stub)
        client.send_notification("textDocument/didChange", {
          "textDocument" => { "uri" => uri, "version" => 2 },
          "contentChanges" => [{ "text" => partial }]
        })

        response = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => uri },
          "position"     => { "line" => dot_line, "character" => dot_char }
        })

        items = response.fetch("result").fetch("items")
        labels = items.map { |i| i["label"] }

        expected.each do |exp|
          assert_includes labels, exp, "#{label}: Expected [#{labels.join(', ')}] to include \"#{exp}\""
        end

        yield items, labels if block_given?
      end
    end
  end

  def test_completion_nested_type_after_dot_on_parent
    with_completion_test(
      source: FULL_SOURCE,
      function: "main",
      stub: "        return Rectangle.\n",
      expected: ["Edge"],
      label: "Rectangle."
    )
  end

  def test_completion_nested_struct_fields_after_dot
    # Replaces "return r.x + r.width + r.top_edge.start" with r.top_edge.
    with_completion_test(
      source: FULL_SOURCE,
      function: "basic_nested_demo",
      stub: "        r.top_edge.\n",
      expected: ["start", "end"],
      label: "r.top_edge."
    )
  end

  def test_completion_level1_fields_after_dot
    with_completion_test(
      source: FULL_SOURCE,
      function: "deeply_nested_demo",
      stub: "        l1.\n",
      expected: ["data", "mid"],
      label: "l1."
    )
  end

  def test_completion_level2_fields_after_dot
    with_completion_test(
      source: FULL_SOURCE,
      function: "deeply_nested_demo",
      stub: "        l1.mid.\n",
      expected: ["tag", "inner"],
      label: "l1.mid."
    )
  end

  def test_completion_deeply_nested_struct_fields
    with_completion_test(
      source: FULL_SOURCE,
      function: "deeply_nested_demo",
      stub: "        l1.mid.inner.\n",
      expected: ["value"],
      label: "l1.mid.inner."
    )
  end

  def test_completion_fields_on_qualified_type_variable
    with_completion_test(
      source: FULL_SOURCE,
      function: "param_nested_demo",
      stub: "        edge.\n",
      expected: ["start", "end"],
      label: "edge. (qualified type)"
    )
  end

  def test_completion_method_on_nested_type_extending
    with_completion_test(
      source: FULL_SOURCE,
      function: "extend_nested_demo",
      stub: "        e.\n",
      expected: ["start", "end", "length"],
      label: "e. (nested type method)"
    )
  end

  def test_completion_deeply_nested_type_chain
    with_completion_test(
      source: FULL_SOURCE,
      function: "deeply_nested_demo",
      stub: "        var v: Level1.Level2.\n",
      expected: ["Level3"],
      label: "Level1.Level2."
    )
  end

  def test_completion_global_scope_includes_top_level_types
    Dir.mktmpdir("mt-lsp-audit-global-comp") do |dir|
      path = File.join(dir, "main.mt")
      File.write(path, FULL_SOURCE)

      with_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})

        uri = path_to_uri(path)
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
        })

        response = client.send_request("textDocument/completion", {
          "textDocument" => { "uri" => uri },
          "position"     => { "line" => 0, "character" => 0 }
        })

        items = response.fetch("result").fetch("items")
        labels = items.map { |i| i["label"] }

        assert_includes labels, "Rectangle"
        assert_includes labels, "Level1"
      end
    end
  end

  # =====================================================================
  # HOVER TESTS — cursor on existing tokens in FULL_SOURCE
  # =====================================================================

  def hover_at(uri, source, match_string)
    line = source.lines.index { |l| l.include?(match_string) }
    char = source.lines[line].index(match_string.split.last)
    [line, char]
  end

  def test_hover_nested_struct_field
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_audit_hover_nested_field.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
      })

      # Hover over r.top_edge.start in basic_nested_demo
      line = NESTED_STRUCT_SOURCE.lines.index { |l| l.include?("r.top_edge.start = 3.0") }
      char = NESTED_STRUCT_SOURCE.lines[line].index("start")

      response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => line, "character" => char }
      })

      result = response.fetch("result")
      value = result.dig("contents", "value")
      assert_includes value, "start: float", "hover should show field type"
    end
  end

  def test_hover_nested_struct_parent_field
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_audit_hover_parent_field.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
      })

      # Hover over r.top_edge (the parent field of nested struct type)
      line = NESTED_STRUCT_SOURCE.lines.index { |l| l.include?("r.top_edge.start = 3.0") }
      char = NESTED_STRUCT_SOURCE.lines[line].index("top_edge")

      response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => line, "character" => char }
      })

      result = response.fetch("result")
      value = result.dig("contents", "value")
      assert_includes value, "top_edge: Edge", "hover should show field type as Edge"
    end
  end

  def test_hover_deeply_nested_struct_field
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_audit_hover_deeply_field.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
      })

      # Hover over l1.mid.inner.value
      line = NESTED_STRUCT_SOURCE.lines.index { |l| l.include?("l1.mid.inner.value = 3.0") }
      char = NESTED_STRUCT_SOURCE.lines[line].index("value")

      response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => line, "character" => char }
      })

      result = response.fetch("result")
      value = result.dig("contents", "value")
      assert_includes value, "value: float", "hover should show deeply nested field type"
    end
  end

  def test_hover_deeply_nested_mid_field
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_audit_hover_mid_field.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
      })

      # Hover over l1.mid.tag
      line = NESTED_STRUCT_SOURCE.lines.index { |l| l.include?("l1.mid.tag = 2") }
      char = NESTED_STRUCT_SOURCE.lines[line].index("tag")

      response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => line, "character" => char }
      })

      result = response.fetch("result")
      value = result.dig("contents", "value")
      assert_includes value, "tag: int", "hover should show tag: int"
    end
  end

  def test_hover_qualified_type_field
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_audit_hover_qualified_field.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
      })

      # Hover over edge.start where edge: Rectangle.Edge
      line = NESTED_STRUCT_SOURCE.lines.index { |l| l.include?("edge.start = 0.0") }
      char = NESTED_STRUCT_SOURCE.lines[line].index("start")

      response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => line, "character" => char }
      })

      result = response.fetch("result")
      value = result.dig("contents", "value")
      assert_includes value, "start: float", "hover should show field on qualified type"
    end
  end

  def test_hover_nested_type_method
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_audit_hover_nested_method.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
      })

      # Hover over e.length() where extending Rectangle.Edge defines length()
      line = NESTED_STRUCT_SOURCE.lines.index { |l| l.include?("return e.length()") }
      char = NESTED_STRUCT_SOURCE.lines[line].index("length")

      response = client.send_request("textDocument/hover", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => line, "character" => char }
      })

      result = response.fetch("result")
      value = result.dig("contents", "value")
      assert_includes value, "length", "hover should show length method info"
    end
  end

  # =====================================================================
  # DEFINITION TESTS — go-to-def on valid tokens
  # =====================================================================

  def test_definition_nested_struct_field_to_declaration
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_audit_def_nested_field.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
      })

      # Go-to-def from r.top_edge.start usage to start: float declaration in Edge
      use_line = NESTED_STRUCT_SOURCE.lines.index { |l| l.include?("r.top_edge.start = 3.0") }
      use_char = NESTED_STRUCT_SOURCE.lines[use_line].index("start")
      def_line = NESTED_STRUCT_SOURCE.lines.index { |l| l.match?(/start:\s+float/) }
      def_char = NESTED_STRUCT_SOURCE.lines[def_line].index("start")

      response = client.send_request("textDocument/definition", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => use_line, "character" => use_char }
      })

      result = response.fetch("result")
      assert_equal def_line, result.dig("range", "start", "line")
      assert_equal def_char, result.dig("range", "start", "character")
    end
  end

  def test_definition_deeply_nested_field_to_declaration
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_audit_def_deeply_field.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
      })

      # Go-to-def from l1.mid.inner.value usage to value: float in Level3
      use_line = NESTED_STRUCT_SOURCE.lines.index { |l| l.include?("l1.mid.inner.value = 3.0") }
      use_char = NESTED_STRUCT_SOURCE.lines[use_line].index("value")
      def_line = NESTED_STRUCT_SOURCE.lines.index { |l| l.match?(/value:\s+float/) }
      def_char = NESTED_STRUCT_SOURCE.lines[def_line].index("value")

      response = client.send_request("textDocument/definition", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => use_line, "character" => use_char }
      })

      result = response.fetch("result")
      assert_equal def_line, result.dig("range", "start", "line")
      assert_equal def_char, result.dig("range", "start", "character")
    end
  end

  def test_definition_nested_type_method_to_declaration
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_audit_def_nested_method.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
      })

      # Go-to-def from e.length() to function length() in extending Rectangle.Edge
      use_line = NESTED_STRUCT_SOURCE.lines.index { |l| l.include?("return e.length()") }
      use_char = NESTED_STRUCT_SOURCE.lines[use_line].index("length")
      def_line = NESTED_STRUCT_SOURCE.lines.index { |l| l.strip == "function length() -> float:" }
      def_char = NESTED_STRUCT_SOURCE.lines[def_line].index("length")

      response = client.send_request("textDocument/definition", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => use_line, "character" => use_char }
      })

      result = response.fetch("result")
      assert_equal def_line, result.dig("range", "start", "line")
      assert_equal def_char, result.dig("range", "start", "character")
    end
  end

  # =====================================================================
  # REFERENCES TESTS — find-references on nested struct tokens
  # =====================================================================

  def test_references_nested_struct_field
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_audit_ref_nested_field.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
      })

      # Find references to Edge.start from the declaration site
      def_line = NESTED_STRUCT_SOURCE.lines.index { |l| l.match?(/start:\s+float/) }
      def_char = NESTED_STRUCT_SOURCE.lines[def_line].index("start")

      response = client.send_request("textDocument/references", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => def_line, "character" => def_char },
        "context"      => { "includeDeclaration" => true }
      })

      locations = response.fetch("result")
      assert_kind_of Array, locations
      assert locations.length >= 5, "expected >= 5 references for nested field 'start', got #{locations.length}"
    end
  end

  def test_references_extending_method_on_nested_type
    with_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_audit_ref_nested_method.mt"
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => FULL_SOURCE }
      })

      # Find references to length() method from the declaration site
      def_line = NESTED_STRUCT_SOURCE.lines.index { |l| l.strip == "function length() -> float:" }
      def_char = NESTED_STRUCT_SOURCE.lines[def_line].index("length")

      response = client.send_request("textDocument/references", {
        "textDocument" => { "uri" => uri },
        "position"     => { "line" => def_line, "character" => def_char },
        "context"      => { "includeDeclaration" => true }
      })

      locations = response.fetch("result")
      assert_kind_of Array, locations
      assert locations.length >= 2, "expected >= 2 references for length(), got #{locations.length}"
    end
  end
end
