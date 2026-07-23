# frozen_string_literal: true

require_relative "helpers"

class CodeActionsTest < Minitest::Test
  include LSPServerTestHelpers

  def test_code_action_returns_source_fixall_action
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_code_action_test.mt"
      source = "function main() -> int:\n    var x = 1\n    return x\n"
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

  def test_source_fixall_preserves_required_match_bindings
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_fixall_match_bindings.mt"
      source = <<~MT
        function main(value: Result[int, str]) -> int:
            match value:
                Result.failure as payload:
                    return payload.error.length()
                Result.success as _:
                    return 0
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => {
          "start" => { "line" => 0, "character" => 0 },
          "end" => { "line" => 5, "character" => 0 }
        },
        "context" => { "diagnostics" => [], "only" => ["source.fixAll"] }
      })

      actions = response.fetch("result")
      fixall = actions.find { |a| a["kind"] == "source.fixAll" }
      assert fixall, "expected a source.fixAll action"
      edit_text = fixall.dig("edit", "changes", uri, 0, "newText")
      assert_includes edit_text, "Result.failure as payload:"
      assert_includes edit_text, "return payload.error.length()"
      assert_includes edit_text, "Result.success:"
      refute_includes edit_text, "Result.success as _:"
    end
  end

  def test_source_fixall_does_not_offer_action_for_line_too_long_only_file
    Dir.mktmpdir("milk-tea-lsp-fixall-line-length") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(File.join(dir, ".mt-lint.yml"), <<~YAML)
        max_line_length: 40
        select:
          - line-too-long
        ignore: []
      YAML

      source = <<~MT
        function main() -> int:
            return log_value("alpha", "beta", "gamma", "delta")
      MT
      uri = path_to_uri(path)

      with_lsp_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/codeAction", {
          "textDocument" => { "uri" => uri },
          "range" => {
            "start" => { "line" => 0, "character" => 0 },
            "end" => { "line" => 2, "character" => 0 }
          },
          "context" => { "diagnostics" => [], "only" => ["source.fixAll"] }
        })

        actions = response.fetch("result")
        refute actions.any? { |action| action["kind"] == "source.fixAll" }
      end
    end
  end

  def test_source_fixall_does_not_offer_action_for_line_too_long_tuple_only_file
    Dir.mktmpdir("milk-tea-lsp-fixall-line-length-tuple") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(File.join(dir, ".mt-lint.yml"), <<~YAML)
        max_line_length: 40
        select:
          - line-too-long
        ignore: []
      YAML

      source = <<~MT
        function main() -> int:
            let pair = (alpha_value, beta_value, gamma_value)
            return 0
      MT
      uri = path_to_uri(path)

      with_lsp_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/codeAction", {
          "textDocument" => { "uri" => uri },
          "range" => {
            "start" => { "line" => 0, "character" => 0 },
            "end" => { "line" => 3, "character" => 0 }
          },
          "context" => { "diagnostics" => [], "only" => ["source.fixAll"] }
        })

        actions = response.fetch("result")
        refute actions.any? { |action| action["kind"] == "source.fixAll" }
      end
    end
  end

  def test_source_fixall_does_not_offer_action_for_line_too_long_condition_only_file
    Dir.mktmpdir("milk-tea-lsp-fixall-line-length-condition") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(File.join(dir, ".mt-lint.yml"), <<~YAML)
        max_line_length: 100
        select:
          - line-too-long
        ignore: []
      YAML

      source = <<~MT
        function main(kind: int, has_byte: bool, ctrl: bool, alt: bool, input_byte: int) -> void:
            if kind == 2 and has_byte and not ctrl and not alt and input_byte >= 32 and input_byte < 127 and input_byte != 64:
                pass
      MT
      uri = path_to_uri(path)

      with_lsp_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/codeAction", {
          "textDocument" => { "uri" => uri },
          "range" => {
            "start" => { "line" => 0, "character" => 0 },
            "end" => { "line" => 3, "character" => 0 }
          },
          "context" => { "diagnostics" => [], "only" => ["source.fixAll"] }
        })

        actions = response.fetch("result")
        refute actions.any? { |action| action["kind"] == "source.fixAll" }
      end
    end
  end

  def test_source_fixall_is_lint_only_and_ignores_formatter_mode_changes
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      client.send_notification("initialized", {})
      uri = "file:///tmp/lsp_fixall_formatter_mode.mt"
      source = <<~MT
        function main() -> int:
            var x = 1
            return x
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      expected = MilkTea::Linter.fix_source(source, path: "demo.mt")

      tidy_response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => {
          "start" => { "line" => 0, "character" => 0 },
          "end" => { "line" => 3, "character" => 0 }
        },
        "context" => { "diagnostics" => [], "only" => ["source.fixAll"] }
      })

      tidy_actions = tidy_response.fetch("result")
      tidy_fixall = tidy_actions.find { |action| action["kind"] == "source.fixAll" }
      assert tidy_fixall, "expected a source.fixAll action for tidy mode"
      assert_equal expected, tidy_fixall.dig("edit", "changes", uri, 0, "newText")

      client.send_notification("workspace/didChangeConfiguration", {
        "settings" => {
          "milkTea" => {
            "format" => {
              "mode" => "safe"
            }
          }
        }
      })

      safe_response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => {
          "start" => { "line" => 0, "character" => 0 },
          "end" => { "line" => 3, "character" => 0 }
        },
        "context" => { "diagnostics" => [], "only" => ["source.fixAll"] }
      })

      safe_actions = safe_response.fetch("result")
      safe_fixall = safe_actions.find { |action| action["kind"] == "source.fixAll" }
      assert safe_fixall, "expected a source.fixAll action for safe mode"
      assert_equal expected, safe_fixall.dig("edit", "changes", uri, 0, "newText")
    end
  end

  def test_code_action_provides_source_fixall_for_workspace_std_files
    Dir.mktmpdir("milk-tea-lsp-code-action-std") do |dir|
      std_dir = File.join(dir, "std")
      Dir.mkdir(File.join(dir, "std"))

      file_path = File.join(std_dir, "demo.mt")
      source = "function main() -> int:\n    var x = 1\n    return x\n"
      File.write(file_path, source)

      root_uri = path_to_uri(dir)
      uri = path_to_uri(file_path)

      with_lsp_server do |client|
        client.send_request("initialize", { "rootUri" => root_uri, "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/codeAction", {
          "textDocument" => { "uri" => uri },
          "range" => {
            "start" => { "line" => 0, "character" => 0 },
            "end" => { "line" => 2, "character" => 14 }
          },
          "context" => { "diagnostics" => [], "only" => ["source.fixAll"] }
        })

        actions = response.fetch("result")
        fixall = actions.find { |a| a["kind"] == "source.fixAll" }
        assert fixall, "expected a source.fixAll action for std file"
        edit_text = fixall.dig("edit", "changes", uri, 0, "newText")
        assert_includes edit_text, "let x = 1"
      end
    end
  end

  def test_code_action_quickfix_prefer_let
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_prefer_let.mt"
      source = <<~MT
        function main() -> int:
            var x = 1
            return x
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      prefer_let_diag = {
        "source" => "milk-tea",
        "code"   => "prefer-let",
        "range"  => { "start" => { "line" => 1, "character" => 4 }, "end" => { "line" => 1, "character" => 13 } },
        "message" => "var 'x' is never reassigned; prefer 'let'"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 1, "character" => 0 }, "end" => { "line" => 1, "character" => 0 } },
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

  def test_code_action_quickfix_reserved_primitive_name
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_reserved_primitive_name.mt"
      source = <<~MT
        function is_ascii_space(byte: ubyte) -> bool:
            let byte_value = byte
            return byte == 32 and byte_value == 32
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      reserved_diag = {
        "source" => "milk-tea",
        "code" => "reserved-primitive-name",
        "range" => { "start" => { "line" => 0, "character" => 24 }, "end" => { "line" => 0, "character" => 28 } },
        "message" => "parameter 'byte' uses reserved built-in type name 'byte'; rename it before this becomes a hard error"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 0, "character" => 24 }, "end" => { "line" => 0, "character" => 28 } },
        "context" => { "diagnostics" => [reserved_diag] }
      })

      actions = response.fetch("result")
      quickfix = actions.find { |action| action["kind"] == "quickFix" && action["title"] == "Rename 'byte' to 'byte_value_2'" }
      assert quickfix, "expected a quickFix action for reserved-primitive-name"
      edits = quickfix.dig("edit", "changes", uri)
      assert_equal 3, edits.length
      assert_equal ["byte_value_2"], edits.map { |edit| edit["newText"] }.uniq
    end
  end

  def test_code_action_quickfix_redundant_else
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_redundant_else.mt"
      source = <<~MT
        function sign(n: int) -> int:
            if n > 0:
                return 1
            else:
                return -1
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      redundant_diag = {
        "source" => "milk-tea",
        "code"   => "redundant-else",
        "range"  => { "start" => { "line" => 4, "character" => 8 }, "end" => { "line" => 4, "character" => 17 } },
        "message" => "else block is redundant because all preceding branches return"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 4, "character" => 0 }, "end" => { "line" => 4, "character" => 0 } },
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


  def test_code_action_quickfix_redundant_return
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_redundant_return.mt"
      source = <<~MT
        function main() -> void:
            let _ = 1
            return
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      redundant_diag = {
        "source" => "milk-tea",
        "code"   => "redundant-return",
        "range"  => { "start" => { "line" => 2, "character" => 4 }, "end" => { "line" => 2, "character" => 10 } },
        "message" => "final bare return in void function is redundant"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 2, "character" => 0 }, "end" => { "line" => 2, "character" => 0 } },
        "context" => { "diagnostics" => [redundant_diag] }
      })

      actions = response.fetch("result")
      quickfix = actions.find { |a| a["kind"] == "quickFix" && a["title"] == "Remove redundant return" }
      assert quickfix, "expected a quickFix action for redundant-return"
      edit = quickfix.dig("edit", "changes", uri, 0)
      assert_equal "", edit["newText"]
      assert_equal({ "line" => 2, "character" => 0 }, edit.dig("range", "start"))
      assert_equal({ "line" => 3, "character" => 0 }, edit.dig("range", "end"))
    end
  end

  def test_code_action_quickfix_line_too_long_wraps_argument_list
    Dir.mktmpdir("milk-tea-lsp-line-too-long") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(File.join(dir, ".mt-lint.yml"), <<~YAML)
        max_line_length: 40
        select:
          - line-too-long
        ignore: []
      YAML

      source = <<~MT
        function main() -> int:
            return log_value("alpha", "beta", "gamma", "delta")
      MT
      uri = path_to_uri(path)

      with_lsp_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/codeAction", {
          "textDocument" => { "uri" => uri },
          "range" => { "start" => { "line" => 1, "character" => 40 }, "end" => { "line" => 1, "character" => 55 } },
          "context" => {
            "diagnostics" => [{
              "source" => "milk-tea",
              "code" => "line-too-long",
              "range" => { "start" => { "line" => 1, "character" => 40 }, "end" => { "line" => 1, "character" => 55 } },
              "message" => "line exceeds max length of 40 columns (55); wrap the expression"
            }]
          }
        })

        actions = response.fetch("result")
        quickfix = actions.find { |action| action["kind"] == "quickFix" && action["title"] == "Wrap long line" }
        assert quickfix, "expected a quickFix action for line-too-long"
        edit = quickfix.dig("edit", "changes", uri, 0)
        assert_includes edit["newText"], "return log_value(\n"
        assert_includes edit["newText"], "        \"delta\"\n"
      end
    end
  end

  def test_code_action_quickfix_line_too_long_wraps_type_argument_list
    Dir.mktmpdir("milk-tea-lsp-line-too-long-type-list") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(File.join(dir, ".mt-lint.yml"), <<~YAML)
        max_line_length: 50
        select:
          - line-too-long
        ignore: []
      YAML

      source = <<~MT
        function main() -> Result[Option[AlphaValue], BetaValue, GammaValue]:
            return 0
      MT
      uri = path_to_uri(path)

      with_lsp_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/codeAction", {
          "textDocument" => { "uri" => uri },
          "range" => { "start" => { "line" => 0, "character" => 50 }, "end" => { "line" => 0, "character" => 68 } },
          "context" => {
            "diagnostics" => [{
              "source" => "milk-tea",
              "code" => "line-too-long",
              "range" => { "start" => { "line" => 0, "character" => 50 }, "end" => { "line" => 0, "character" => 68 } },
              "message" => "line exceeds max length of 50 columns (68); wrap the expression"
            }]
          }
        })

        actions = response.fetch("result")
        quickfix = actions.find { |action| action["kind"] == "quickFix" && action["title"] == "Wrap long line" }
        assert quickfix, "expected a quickFix action for line-too-long"
        edit = quickfix.dig("edit", "changes", uri, 0)
        assert_includes edit["newText"], "function main() -> Result[\n"
        assert_includes edit["newText"], "    Option[AlphaValue],\n"
        assert_includes edit["newText"], "    GammaValue\n"
      end
    end
  end

  def test_code_action_quickfix_line_too_long_wraps_if_logical_chain
    Dir.mktmpdir("milk-tea-lsp-line-too-long-condition") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(File.join(dir, ".mt-lint.yml"), <<~YAML)
        max_line_length: 100
        select:
          - line-too-long
        ignore: []
      YAML

      source = <<~MT
        function main(kind: int, has_byte: bool, ctrl: bool, alt: bool, input_byte: int) -> void:
            if kind == 2 and has_byte and not ctrl and not alt and input_byte >= 32 and input_byte < 127 and input_byte != 64:
                pass
      MT
      uri = path_to_uri(path)

      with_lsp_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/codeAction", {
          "textDocument" => { "uri" => uri },
          "range" => { "start" => { "line" => 1, "character" => 100 }, "end" => { "line" => 1, "character" => 114 } },
          "context" => {
            "diagnostics" => [{
              "source" => "milk-tea",
              "code" => "line-too-long",
              "range" => { "start" => { "line" => 1, "character" => 100 }, "end" => { "line" => 1, "character" => 114 } },
              "message" => "line exceeds max length of 100 columns (114); wrap the expression"
            }]
          }
        })

        actions = response.fetch("result")
        quickfix = actions.find { |action| action["kind"] == "quickFix" && action["title"] == "Wrap long line" }
        assert quickfix, "expected a quickFix action for line-too-long"
        edit = quickfix.dig("edit", "changes", uri, 0)
        assert_includes edit["newText"], "    if (\n"
        assert_includes edit["newText"], "        and has_byte\n"
        assert_includes edit["newText"], "        and input_byte != 64\n"
        assert_includes edit["newText"], "    ):\n"
      end
    end
  end

  def test_code_action_quickfix_line_too_long_wraps_else_if_logical_chain
    Dir.mktmpdir("milk-tea-lsp-line-too-long-else-if") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(File.join(dir, ".mt-lint.yml"), <<~YAML)
        max_line_length: 90
        select:
          - line-too-long
        ignore: []
      YAML

      source = <<~MT
        function main(flag: bool, value: int, other: int) -> int:
            if flag:
                return 1
            else if flag and value > 0 and other > 0 and value != other and other < 100 and value < 200:
                return 2
            return 0
      MT
      uri = path_to_uri(path)

      with_lsp_server do |client|
        client.send_request("initialize", { "rootUri" => path_to_uri(dir), "capabilities" => {} })
        client.send_notification("initialized", {})
        client.send_notification("textDocument/didOpen", {
          "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
        })

        response = client.send_request("textDocument/codeAction", {
          "textDocument" => { "uri" => uri },
          "range" => { "start" => { "line" => 3, "character" => 90 }, "end" => { "line" => 3, "character" => 101 } },
          "context" => {
            "diagnostics" => [{
              "source" => "milk-tea",
              "code" => "line-too-long",
              "range" => { "start" => { "line" => 3, "character" => 90 }, "end" => { "line" => 3, "character" => 101 } },
              "message" => "line exceeds max length of 90 columns (101); wrap the expression"
            }]
          }
        })

        actions = response.fetch("result")
        quickfix = actions.find { |action| action["kind"] == "quickFix" && action["title"] == "Wrap long line" }
        assert quickfix, "expected a quickFix action for line-too-long"
        edit = quickfix.dig("edit", "changes", uri, 0)
        assert_includes edit["newText"], "    else if (\n"
        assert_includes edit["newText"], "        and value > 0\n"
        assert_includes edit["newText"], "        and value < 200\n"
        assert_includes edit["newText"], "    ):\n"
      end
    end
  end

  def test_code_action_quickfix_redundant_ignored_match_binding
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_redundant_ignored_match_binding.mt"
      source = <<~MT
        function main(value: Option[int]) -> int:
            match value:
                Option.some as _:
                    return 1
                Option.none:
                    return 0
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      span_start = source.lines[2].index(" as _")
      span_end = span_start + " as _".length

      redundant_diag = {
        "source" => "milk-tea",
        "code" => "redundant-ignored-match-binding",
        "range" => { "start" => { "line" => 2, "character" => span_start }, "end" => { "line" => 2, "character" => span_end } },
        "message" => "ignored match binding is redundant; remove 'as _'"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 2, "character" => span_start }, "end" => { "line" => 2, "character" => span_end } },
        "context" => { "diagnostics" => [redundant_diag] }
      })

      actions = response.fetch("result")
      quickfix = actions.find { |a| a["kind"] == "quickFix" && a["title"] == "Remove redundant as _" }
      assert quickfix, "expected a quickFix action for redundant-ignored-match-binding"
      edit = quickfix.dig("edit", "changes", uri, 0)
      assert_equal "", edit["newText"]
      assert_equal({ "line" => 2, "character" => span_start }, edit.dig("range", "start"))
      assert_equal({ "line" => 2, "character" => span_end }, edit.dig("range", "end"))
    end
  end

  def test_code_action_quickfix_prefer_let_else
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_prefer_let_else.mt"
      source = <<~MT
        function maybe_handle(handle: ptr[int]?) -> ptr[int]?:
            return handle

        function main(handle: ptr[int]?) -> int:
            let value_ptr = maybe_handle(handle)
            if value_ptr == null:
                return 0
            unsafe:
                return read(value_ptr)
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      prefer_diag = {
        "source" => "milk-tea",
        "code" => "prefer-let-else",
        "range" => { "start" => { "line" => 5, "character" => 4 }, "end" => { "line" => 5, "character" => 24 } },
        "message" => "nullable guard for 'value_ptr' can use let ... else"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 5, "character" => 4 }, "end" => { "line" => 5, "character" => 24 } },
        "context" => { "diagnostics" => [prefer_diag] }
      })

      actions = response.fetch("result")
      quickfix = actions.find { |a| a["kind"] == "quickFix" && a["title"] == "Rewrite as let-else" }
      assert quickfix, "expected a quickFix action for prefer-let-else"
      edit = quickfix.dig("edit", "changes", uri, 0)
      assert_equal "    let value_ptr = maybe_handle(handle) else:\n", edit["newText"]
    end
  end

  def test_code_action_quickfix_prefer_var_else
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_prefer_var_else.mt"
      source = <<~MT
        function maybe_handle(handle: ptr[int]?) -> ptr[int]?:
            return handle

        function main(handle: ptr[int]?) -> int:
            var value_ptr = maybe_handle(handle)
            if value_ptr == null:
                return 0
            unsafe:
                return read(value_ptr)
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      prefer_diag = {
        "source" => "milk-tea",
        "code" => "prefer-var-else",
        "range" => { "start" => { "line" => 5, "character" => 4 }, "end" => { "line" => 5, "character" => 24 } },
        "message" => "nullable guard for 'value_ptr' can use var ... else"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 5, "character" => 4 }, "end" => { "line" => 5, "character" => 24 } },
        "context" => { "diagnostics" => [prefer_diag] }
      })

      actions = response.fetch("result")
      quickfix = actions.find { |a| a["kind"] == "quickFix" && a["title"] == "Rewrite as var-else" }
      assert quickfix, "expected a quickFix action for prefer-var-else"
      edit = quickfix.dig("edit", "changes", uri, 0)
      assert_equal "    var value_ptr = maybe_handle(handle) else:\n", edit["newText"]
    end
  end

  def test_code_action_quickfix_redundant_bool_compare
    with_lsp_server do |client|
      client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      uri = "file:///tmp/lsp_quickfix_redundant_bool_compare.mt"
      source = <<~MT
        function main(flag: bool) -> int:
            if flag != true:
                return 1
            return 0
      MT
      client.send_notification("textDocument/didOpen", {
        "textDocument" => { "uri" => uri, "languageId" => "milk-tea", "version" => 1, "text" => source }
      })

      expression_start = source.lines[1].index("flag != true")
      expression_end = expression_start + "flag != true".length

      redundant_diag = {
        "source" => "milk-tea",
        "code" => "redundant-bool-compare",
        "range" => { "start" => { "line" => 1, "character" => expression_start }, "end" => { "line" => 1, "character" => expression_end } },
        "message" => "boolean comparison against literal is redundant; invert the expression with 'not'"
      }

      response = client.send_request("textDocument/codeAction", {
        "textDocument" => { "uri" => uri },
        "range" => { "start" => { "line" => 1, "character" => expression_start }, "end" => { "line" => 1, "character" => expression_end } },
        "context" => { "diagnostics" => [redundant_diag] }
      })

      actions = response.fetch("result")
      quickfix = actions.find { |a| a["kind"] == "quickFix" && a["title"] == "Simplify boolean comparison" }
      assert quickfix, "expected a quickFix action for redundant-bool-compare"
      edit = quickfix.dig("edit", "changes", uri, 0)
      assert_equal "not flag", edit["newText"]
      assert_equal({ "line" => 1, "character" => expression_start }, edit.dig("range", "start"))
      assert_equal({ "line" => 1, "character" => expression_end }, edit.dig("range", "end"))
    end
  end

  def test_initialize_advertises_quickfix_code_action_kind
    with_lsp_server do |client|
      response = client.send_request("initialize", { "rootUri" => nil, "capabilities" => {} })
      kinds = response.dig("result", "capabilities", "codeActionProvider", "codeActionKinds")
      assert_includes kinds, "quickFix"
      assert_includes kinds, "source.fixAll"
    end
  end

end
