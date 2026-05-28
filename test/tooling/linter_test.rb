# frozen_string_literal: true

require "fileutils"
require "tmpdir"

require_relative "../test_helper"

class MilkTeaLinterTest < Minitest::Test
  def test_warns_on_line_too_long_using_file_uri_config
    Dir.mktmpdir("milk-tea-linter-line-too-long-uri") do |dir|
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

      warnings = MilkTea::Linter.lint_source(source, path: "file://#{path}")

      warning = warnings.find { |entry| entry.code == "line-too-long" }
      assert warning, "expected line-too-long warning"
      assert_equal 2, warning.line
      assert_equal 41, warning.column
      assert_match(/line exceeds max length of 40 columns/, warning.message)
    end
  end

  def test_fix_source_wraps_long_call_arguments_for_line_too_long
    Dir.mktmpdir("milk-tea-linter-fix-line-too-long") do |dir|
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

      fixed = MilkTea::Linter.fix_source(source, path: path)

      assert_includes fixed, "return log_value(\n"
      assert_includes fixed, "        \"alpha\",\n"
      assert_includes fixed, "        \"delta\",\n"
      refute_includes fixed, "return log_value(\"alpha\", \"beta\", \"gamma\", \"delta\")"
    end
  end

  def test_fix_source_wraps_long_tuple_literal_without_trailing_comma
    Dir.mktmpdir("milk-tea-linter-fix-line-too-long-tuple") do |dir|
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

      fixed = MilkTea::Linter.fix_source(source, path: path)

      assert_includes fixed, "let pair = (\n"
      assert_includes fixed, "        alpha_value,\n"
      assert_includes fixed, "        gamma_value\n"
      refute_includes fixed, "        gamma_value,\n"
    end
  end

  def test_fix_source_wraps_long_type_argument_list_for_line_too_long
    Dir.mktmpdir("milk-tea-linter-fix-line-too-long-type-list") do |dir|
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

      fixed = MilkTea::Linter.fix_source(source, path: path)

      assert_includes fixed, "function main() -> Result[\n"
      assert_includes fixed, "    Option[AlphaValue],\n"
      assert_includes fixed, "    GammaValue,\n"
      assert_includes fixed, "]:\n"
    end
  end

  def test_fix_source_wraps_long_if_logical_chain_for_line_too_long
    Dir.mktmpdir("milk-tea-linter-fix-line-too-long-condition") do |dir|
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

      fixed = MilkTea::Linter.fix_source(source, path: path)

      assert_includes fixed, "    if (\n"
      assert_includes fixed, "        kind == 2\n"
      assert_includes fixed, "        and input_byte != 64\n"
      assert_includes fixed, "    ):\n"
    end
  end

  def test_fix_source_wraps_long_else_if_logical_chain_for_line_too_long
    Dir.mktmpdir("milk-tea-linter-fix-line-too-long-else-if") do |dir|
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

      fixed = MilkTea::Linter.fix_source(source, path: path)

      assert_includes fixed, "    else if (\n"
      assert_includes fixed, "        flag\n"
      assert_includes fixed, "        and value < 200\n"
      assert_includes fixed, "    ):\n"
    end
  end

  def test_warns_on_redundant_ignored_match_binding
    source = <<~MT
      function main(value: Option[int]) -> int:
          match value:
              Option.some as _:
                  return 1
              Option.none:
                  return 0
    MT
    warnings = MilkTea::Linter.lint_source(source, path: "demo.mt")

    warning = warnings.find { |entry| entry.code == "redundant-ignored-match-binding" }
    assert warning, "expected redundant ignored match binding warning"
    span_start = source.lines[2].index(" as _")
    assert_equal 3, warning.line
    assert_equal span_start + 1, warning.column
    assert_equal 5, warning.length
    assert_equal :hint, warning.severity
    assert_match(/remove 'as _'/, warning.message)
  end

  def test_warns_on_local_named_after_reserved_primitive_type
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          let byte = 1
          return byte
    MT

    assert_equal 1, warnings.length
    warning = warnings.first
    assert_equal "reserved-primitive-name", warning.code
    assert_equal 2, warning.line
    assert_match(/local 'byte' uses reserved built-in type name 'byte'/, warning.message)
  end

  def test_warns_on_local_named_after_reserved_builtin_result_type
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          let Result = 1
          return Result
    MT

    assert_equal 1, warnings.length
    warning = warnings.first
    assert_equal "reserved-primitive-name", warning.code
    assert_equal 2, warning.line
    assert_match(/local 'Result' uses reserved built-in type name 'Result'/, warning.message)
  end

  def test_warns_on_import_alias_named_after_reserved_builtin_result_type
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      import std.async as Result

      function main() -> int:
          return 0
    MT

    warning = warnings.find { |entry| entry.code == "reserved-primitive-name" }
    assert warning, "expected reserved-name warning for import alias Result"
    assert_equal "reserved-primitive-name", warning.code
    assert_equal 1, warning.line
    assert_match(/import alias 'Result' uses reserved built-in type name 'Result'/, warning.message)
  end

  def test_does_not_warn_on_import_alias_named_after_primitive_type
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      import std.async as str

      function main() -> int:
          return 0
    MT

    refute warnings.any? { |warning| warning.code == "reserved-primitive-name" && warning.message.include?("str") }
  end

  def test_does_not_warn_on_local_named_after_non_reserved_builtin_type_name
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          let span = 1
          return span
    MT

    refute warnings.any? { |warning| warning.code == "reserved-primitive-name" }
  end

  def test_warns_on_type_parameter_named_after_non_primitive_builtin_type
    source = <<~MT
      function identity[span](value: span) -> span:
          return value
    MT
    warnings = MilkTea::Linter.lint_source(source, path: "demo.mt")

    assert_equal 1, warnings.length
    warning = warnings.first
    assert_equal "reserved-primitive-name", warning.code
    assert_equal 1, warning.line
    assert_equal source.lines.first.index("span") + 1, warning.column
    assert_match(/type parameter 'span' uses reserved built-in type name 'span'/, warning.message)
  end

  def test_warns_on_parameter_named_after_reserved_primitive_type
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["unused-param"])
      function main(byte: int) -> int:
          return byte
    MT

    assert_equal 1, warnings.length
    warning = warnings.first
    assert_equal "reserved-primitive-name", warning.code
    assert_equal 1, warning.line
    assert_match(/parameter 'byte' uses reserved built-in type name 'byte'/, warning.message)
  end

  def test_warns_on_function_named_after_reserved_primitive_type
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function double(value: int) -> int:
          return value * 2

      function main() -> int:
          return double(3)
    MT

    assert_equal 1, warnings.length
    warning = warnings.first
    assert_equal "reserved-primitive-name", warning.code
    assert_equal 1, warning.line
    assert_match(/function 'double' uses reserved built-in type name 'double'/, warning.message)
  end

  def test_reserved_primitive_name_lint_handles_declarations_without_column_metadata
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      const float: int = 1
      var double: int = 2
    MT
    warnings += MilkTea::Linter.lint_source(<<~MT, path: "extern.mt")
      external

      external function int() -> void
    MT

    assert_equal ["reserved-primitive-name", "reserved-primitive-name", "reserved-primitive-name"], warnings.map(&:code)
    assert_equal [1, 2, 3], warnings.map(&:line)
    assert_equal ["float", "double", "int"], warnings.map(&:symbol_name)
    assert_equal [nil, nil, nil], warnings.map(&:column)
  end

  def test_fix_source_renames_reserved_primitive_parameter_and_local_uses
    source = <<~MT
      function is_ascii_space(byte: ubyte) -> bool:
          let byte_value = byte
          return byte == 32 and byte_value == 32
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    assert_includes fixed, "function is_ascii_space(byte_value_2: ubyte) -> bool:"
    assert_includes fixed, "let byte_value = byte_value_2"
    assert_includes fixed, "return byte_value_2 == 32 and byte_value == 32"
    refute_includes fixed, "function is_ascii_space(byte: ubyte) -> bool:"
  end

  def test_reports_unused_local_with_line_number
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          let unused = 1
          return 0
    MT

    assert_equal 1, warnings.length
    warning = warnings.first
    assert_equal "demo.mt", warning.path
    assert_equal 2, warning.line
    assert_equal "unused-local", warning.code
    assert_match(/unused local 'unused'/, warning.message)
  end

  def test_does_not_report_used_local
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          let used = 1
          return used
    MT

    assert_equal [], warnings
  end

  def test_reports_only_shadowed_unused_binding
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["constant-condition"])
      function main() -> int:
          let value = 1
          if true:
              let value = 2
          return value
    MT

    # Inner `value` is both a shadow and unused; outer `value` is used (returned)
    assert_equal 2, warnings.length
    codes = warnings.map(&:code)
    assert_includes codes, "shadow"
    assert_includes codes, "unused-local"
    # Both warnings point to the inner declaration line
    warnings.each { |w| assert_equal 4, w.line }
  end

  def test_ignores_intentionally_discarded_locals
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          let _unused = 1
          return 0
    MT

    assert_equal [], warnings
  end

  def test_counts_compound_assignment_as_use
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          var total = 1
          total += 2
          return total
    MT

    assert_equal [], warnings
  end

  # ── unused-param ────────────────────────────────────────────────────

  def test_reports_unused_param
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function add(a: int, b: int) -> int:
          return a
    MT

    assert_equal 1, warnings.length
    w = warnings.first
    assert_equal "unused-param", w.code
    assert_match(/unused parameter 'b'/, w.message)
    assert_equal 1, w.line
  end

  def test_does_not_report_used_param
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function add(a: int, b: int) -> int:
          return a + b
    MT

    assert_equal [], warnings
  end

  def test_ignores_underscore_param
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function callback(_event: int) -> int:
          return 0
    MT

    assert_equal [], warnings
  end

  # ── prefer-let ──────────────────────────────────────────────────────

  def test_prefer_let_for_var_never_reassigned
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          var value = 42
          return value
    MT

    assert_equal 1, warnings.length
    w = warnings.first
    assert_equal "prefer-let", w.code
    assert_match(/never reassigned/, w.message)
    assert_match(/'value'/, w.message)
    assert_equal 2, w.line
  end

  def test_no_prefer_let_when_var_is_reassigned
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          var counter = 0
          counter = counter + 1
          return counter
    MT

    assert_equal [], warnings
  end

  def test_no_prefer_let_when_var_is_mutated_via_editable_method
    source = <<~MT
      struct Counter:
          value: int

      extending Counter:
          mutable function bump():
              this.value += 1

      function main() -> int:
          var counter = Counter(value = 0)
          counter.bump()
          return counter.value
    MT

    ast = MilkTea::Parser.parse(source, path: "demo.mt")
    analysis = MilkTea::Sema.check(ast, imported_modules: {})
    warnings = MilkTea::Linter.lint_source(source, path: "demo.mt", sema_facts: analysis)

    refute warnings.any? { |warning| warning.code == "prefer-let" && warning.message.include?("counter") }
  end

  def test_no_prefer_let_when_var_is_only_mutated_via_method_and_sema_is_unavailable
    warnings = MilkTea::Linter.lint_source(<<~MT)
      import missing.module as missing

      struct Counter:
          value: int

      extending Counter:
          mutable function bump() -> void:
              this.value += 1

      function main() -> int:
          var counter = Counter(value = 0)
          counter.bump()
          return counter.value
    MT

    refute warnings.any? { |warning| warning.code == "prefer-let" && warning.message.include?("counter") }
  end

  def test_best_effort_lint_context_analyzes_std_string
    path = File.join(MilkTea.root, "std/string.mt")
    source = File.read(path)

    context = MilkTea::Linter.best_effort_lint_context(source, path: path)

    assert context[:facts], "expected std/string.mt to produce sema facts"
    assert context[:sema_snapshot], "expected std/string.mt to expose sema snapshot"
    assert_equal context[:facts], context[:sema_snapshot].facts
    assert_equal [], Array(context[:errors])
  end

  def test_best_effort_lint_context_resolves_platform_imports_for_std_fs_linux
    path = File.join(MilkTea.root, "std/fs.linux.mt")
    source = File.read(path)

    context = MilkTea::Linter.best_effort_lint_context(source, path: path)

    assert context[:facts], "expected std/fs.linux.mt to produce sema facts"
    assert_includes context[:imported_modules].keys, "std.c.fs"
  end

  def test_best_effort_lint_context_analyzes_std_uri_with_erroring_dependencies
    path = File.join(MilkTea.root, "std/uri.mt")
    source = File.read(path)

    context = MilkTea::Linter.best_effort_lint_context(source, path: path)

    assert context[:facts], "expected std/uri.mt to produce sema facts even when dependencies have collected errors"
  end

  def test_no_prefer_let_when_var_is_exposed_through_ptr_of_alias
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          var data = array[int, 1](0)
          let alias_ptr = ptr_of(data[0])
          return data[0]
    MT

    refute warnings.any? { |warning| warning.code == "prefer-let" && warning.message.include?("data") }
  end

  def test_no_prefer_let_inside_generic_method_body
    source = <<~MT
      struct Box[T]:
          value: T

      extending Box[T]:
          mutable function set(value: T):
              this.value = value

          static function build(value: T) -> Box[T]:
              var result = Box[T](value = value)
              result.set(value)
              return result
    MT

    ast = MilkTea::Parser.parse(source, path: "demo.mt")
    analysis = MilkTea::Sema.check(ast, imported_modules: {})
    warnings = MilkTea::Linter.lint_source(source, path: "demo.mt", sema_facts: analysis)

    refute warnings.any? { |warning| warning.code == "prefer-let" && warning.message.include?("result") }
  end

  def test_no_prefer_let_for_let_locals
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          let value = 42
          return value
    MT

    assert_equal [], warnings
  end

  # ── unreachable-code ────────────────────────────────────────────────

  def test_unreachable_code_after_return
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          return 0
          let dead = 1
    MT

    assert_equal 1, warnings.length
    w = warnings.first
    assert_equal "unreachable-code", w.code
    assert_match(/unreachable/, w.message)
    assert_equal 3, w.line
    assert_equal 9, w.column
    assert_equal 4, w.length
  end

  def test_no_unreachable_before_return
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          let x = 1
          return x
    MT

    assert_equal [], warnings
  end

  def test_unreachable_after_all_branches_terminate
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["missing-return"])
      function main(flag: bool) -> int:
          if flag:
              return 1
          else:
              return 2
          let dead = 3
    MT

    unreachable = warnings.select { |w| w.code == "unreachable-code" }
    assert_equal 1, unreachable.length
    assert_equal 6, unreachable.first.line
    assert_equal 9, unreachable.first.column
    assert_equal 4, unreachable.first.length
  end

  def test_unreachable_return_anchors_to_return_keyword
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["missing-return"])
      function main(flag: bool) -> int:
          if flag:
              return 1
          else:
              return 2
          return -1
    MT

    unreachable = warnings.select { |w| w.code == "unreachable-code" }
    assert_equal 1, unreachable.length
    assert_equal 6, unreachable.first.line
    assert_equal 5, unreachable.first.column
    assert_equal 6, unreachable.first.length
  end

  # ── borrow-and-mutate ────────────────────────────────────────────────

  def test_borrow_and_mutate_warns_on_aliasing
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      import std.mem

      function foo(n: int) -> int:
          var x: int = n
          let p = ref_of(x)
          x = 42
          return read(p)
    MT

    borrow = warnings.select { |w| w.code == "borrow-and-mutate" }
    refute_empty borrow
    assert_match(/x/, borrow.first.message)
    assert_equal 5, borrow.first.line
    assert_equal 20, borrow.first.column
    assert_equal 1, borrow.first.length
  end

  def test_no_borrow_warn_when_no_write_after_borrow
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      import std.mem

      function foo(n: int) -> int:
          var x: int = n
          let p = ref_of(x)
          return read(p)
    MT

    borrow = warnings.select { |w| w.code == "borrow-and-mutate" }
    assert_empty borrow
  end

  def test_no_borrow_warn_for_temporary_ptr_of_call_argument_then_write
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function consume(_value: ptr[int]) -> void:
          return

      function foo(n: int) -> int:
          var x: int = n
          consume(ptr_of(x))
          x = 42
          return x
    MT

    borrow = warnings.select { |w| w.code == "borrow-and-mutate" }
    assert_empty borrow
  end

  # ── unused-import ────────────────────────────────────────────────────

  def test_reports_unused_import
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      import std.string

      function main() -> int:
          return 0
    MT

    assert_equal 1, warnings.length
    w = warnings.first
    assert_equal "unused-import", w.code
    assert_match(/unused import 'string'/, w.message)
    assert_equal 1, w.line
  end

  def test_does_not_report_import_used_in_expression
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      import std.string

      function main() -> int:
          let _value = string.String.create()
          return 0
    MT

    assert_equal [], warnings
  end

  def test_does_not_report_import_used_as_type_ref
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      import std.string

      function process(_value: string.String) -> int:
          return 0
    MT

    assert_equal [], warnings
  end

  def test_does_not_report_import_used_only_for_imported_methods
    Dir.mktmpdir("linter_method_only_import") do |dir|
      std_dir = File.join(dir, "std")
      FileUtils.mkdir_p(std_dir)

      File.write(File.join(std_dir, "string.mt"), <<~MT)
        public struct String:
            value: str

        extending String:
            public function as_str() -> str:
                return this.value
      MT

      File.write(File.join(dir, "util.mt"), <<~MT)
        import std.string as string

        public function make() -> string.String:
            return string.String(value = "hi")
      MT

      path = File.join(dir, "main.mt")
      source = <<~MT
        import util
        import std.string as string

        function main() -> str:
            let value = util.make()
            return value.as_str()
      MT
      File.write(path, source)

      ast = MilkTea::Parser.parse(source, path: path)
      loader = MilkTea::ModuleLoader.new(module_roots: [dir])
      analysis = MilkTea::Sema.check(ast, imported_modules: loader.imported_modules_for_ast(ast))
      warnings = MilkTea::Linter.lint_source(source, path: path, sema_facts: analysis)

      refute warnings.any? { |warning| warning.code == "unused-import" && warning.message.include?("string") }
    end
  end

  def test_does_not_report_import_used_only_in_foreign_mapping
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      import std.c.string as c

      public foreign function compare(left: str as cstr, right: str as cstr) -> int = c.mt_string_strcmp
    MT

    refute warnings.any? { |warning| warning.code == "unused-import" && warning.message.include?("c") }
  end

  def test_does_not_report_import_used_only_in_extern_function_signature
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "extern.mt")
      external

      import std.c.raylib as rl

      external function scale(v: rl.Vector2) -> rl.Vector2
    MT

    refute warnings.any? { |warning| warning.code == "unused-import" && warning.message.include?("rl") }
  end

  def test_does_not_report_import_used_in_match_arm_pattern
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")


      function main() -> int:
          let value = Option[int].none()
          match value:
              Option.none:
                  return 0
              Option.some as payload:
                  return payload.value
    MT

    refute warnings.any? { |warning| warning.code == "unused-import" && warning.message.include?("maybe") }
  end

  def test_import_with_alias_uses_alias_name
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      import std.string as s

      function main() -> int:
          return 0
    MT

    assert_equal 1, warnings.length
    w = warnings.first
    assert_equal "unused-import", w.code
    assert_match(/unused import 's'/, w.message)
  end

  def test_does_not_report_unresolved_import_as_unused
    Dir.mktmpdir("linter_unresolved_import") do |dir|
      path = File.join(dir, "main.mt")
      source = <<~MT

        import test

        function main() -> int:
            let value = Option[int].some(7)
            return value.value
      MT
      File.write(path, source)

      warnings = MilkTea::Linter.lint_source(source, path: path)

      refute warnings.any? { |warning| warning.code == "unused-import" && warning.message.include?("test") }
    end
  end

  # ── dead-assignment ────────────────────────────────────────────────────

  def test_dead_assignment_plain_assignment_value_overwritten
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          var x: int
          x = 1
          x = 2
          return x
    MT

    assert_equal 1, warnings.length
    w = warnings.first
    assert_equal "dead-assignment", w.code
    assert_match(/'x'/, w.message)
    assert_equal 3, w.line
  end

  def test_no_dead_assignment_when_value_is_read
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          var x = 1
          let _y = x
          x = 2
          return x
    MT

    assert_equal [], warnings
  end

  def test_dead_assignment_write_only_tail
    # x is read once,: overwritten and the last write is never read
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          var x = 1
          let _y = x
          x = 2
          return 0
    MT

    assert_equal 1, warnings.length
    assert_equal "dead-assignment", warnings.first.code
    assert_equal 4, warnings.first.line
  end

  def test_no_dead_assignment_when_never_assigned_initial_value
    # Declaration without value: immediate use
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          var x: int
          x = 5
          return x
    MT

    assert_equal [], warnings
  end

  def test_no_dead_assignment_for_unused_local
    # unused-local should fire, not dead-assignment
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          let unused = 1
          return 0
    MT

    codes = warnings.map(&:code)
    assert_includes codes, "unused-local"
    refute_includes codes, "dead-assignment"
  end

  def test_no_dead_assignment_for_while_counter_backedge_read
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          var index: int = 0
          while index < 3:
              index += 1
          return index
    MT

    refute warnings.any? { |w| w.code == "dead-assignment" }
  end

  def test_no_dead_assignment_for_conditional_overwrite
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main(cond: bool) -> int:
          var count: int = 0
          if cond:
              count = 1
          return count
    MT

    refute warnings.any? { |w| w.code == "dead-assignment" }
  end

  def test_no_dead_assignment_for_loop_init_placeholder
    # `var x = false` before a while loop that overwrites x as its first action
    # is an idiomatic placeholder pattern. The initial value is technically dead
    # (the loop might not run), but warning about it is noise.
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> bool:
          var use_ttf = false
          var counter: int = 0
          while counter < 10:
              use_ttf = counter > 5
              counter += 1
          return use_ttf
    MT

    refute warnings.any? { |w| w.code == "dead-assignment" }
  end

  def test_no_dead_assignment_for_initializer_overwritten_on_all_paths
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main(cond: bool) -> int:
          var x: int = 0
          if cond:
              x = 1
          else:
              x = 2
          return x
    MT

    refute warnings.any? { |w| w.code == "dead-assignment" }
  end

  def test_dead_assignment_when_overwritten_on_all_paths
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main(cond: bool) -> int:
          var x: int = 0
          if cond:
              x = 1
          else:
              x = 2
          x = 3
          return x
    MT

    dead = warnings.select { |w| w.code == "dead-assignment" }
    assert_equal 2, dead.length
    lines = dead.map(&:line).sort
    assert_equal [4, 6], lines
  end

  # ── fix_source ─────────────────────────────────────────────────────────

  def test_fix_source_converts_prefer_let
    source = <<~MT
      function main() -> int:
          var x = 1
          return x
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    assert_includes fixed, "let x = 1"
    refute_includes fixed, "var x = 1"
  end

  def test_fix_source_leaves_legitimately_mutable_var
    source = <<~MT
      function main() -> int:
          var x = 1
          x = 2
          return x
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    # var x should stay — it IS mutated
    assert_includes fixed, "var x = 1"
  end

  def test_fix_source_returns_same_source_when_nothing_fixable
    source = <<~MT
      function main() -> int:
          let x = 1
          return x
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")
    assert_equal source, fixed
  end

  # ── missing-return ─────────────────────────────────────────────────────

  def test_missing_return_warns_when_no_return
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function compute() -> int:
          let _x = 1
    MT

    assert_equal 1, warnings.length
    w = warnings.first
    assert_equal "missing-return", w.code
    assert_match(/compute/, w.message)
    assert_equal 1, w.line
  end

  def test_missing_return_no_warn_when_always_returns
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function compute() -> int:
          return 42
    MT

    refute_any(warnings, "missing-return")
  end

  def test_missing_return_no_warn_for_void_function
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function setup():
          let _x = 1
    MT

    assert_equal [], warnings
  end

  def test_missing_return_if_else_both_return
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function pick(flag: bool) -> int:
          if flag:
              return 1
          else:
              return 2
    MT

    refute_any(warnings, "missing-return")
  end

  def test_missing_return_if_without_else_warns
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function pick(flag: bool) -> int:
          if flag:
              return 1
    MT

    assert_any(warnings, "missing-return")
  end

  def test_missing_return_no_warn_when_other_path_fatals
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["redundant-else"])
      function pick(flag: bool) -> int:
          if flag:
              fatal(c"boom")
          else:
              return 1
    MT

    refute_any(warnings, "missing-return")
  end

  def test_missing_return_no_warn_for_while_true_without_break
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function spin(flag: bool) -> int:
          while true:
              if flag:
                  continue
    MT

    refute_any(warnings, "missing-return")
  end

  def test_missing_return_warns_for_while_true_with_break
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function spin(flag: bool) -> int:
          while true:
              if flag:
                  break
    MT

    assert_any(warnings, "missing-return")
  end

  # ── lint: ignore inline suppression ────────────────────────────────────

  def test_lint_ignore_suppresses_warning_on_same_line
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          let unused = 1 # lint: ignore
          return 0
    MT

    assert_equal [], warnings
  end

  def test_lint_ignore_rule_code_suppresses_specific_rule
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          let unused = 1 # lint: ignore(unused-local)
          return 0
    MT

    assert_equal [], warnings
  end

  def test_lint_ignore_rule_code_does_not_suppress_other_rules
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          var unused = 1 # lint: ignore(prefer-let)
          return 0
    MT

    # prefer-let suppressed, unused-local still emitted
    assert_equal 1, warnings.length
    assert_equal "unused-local", warnings.first.code
  end

  def test_lint_ignore_leading_comment_suppresses_next_line
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          # lint: ignore(unused-local)
          let unused = 1
          return 0
    MT

    assert_equal [], warnings
  end

  # ── --select / --ignore rule filtering (via lint_source kwargs) ─────────

  def test_select_limits_to_given_rules
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", select: Set["unused-local"])
      function compute(x: int) -> int:
          let unused = 1
          return 0
    MT

    # unused-param would also fire without select; only unused-local expected
    assert_equal 1, warnings.length
    assert_equal "unused-local", warnings.first.code
  end

  def test_ignore_excludes_given_rules
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["unused-param"])
      function compute(x: int) -> int:
          let unused = 1
          return 0
    MT

    codes = warnings.map(&:code)
    refute_includes codes, "unused-param"
    assert_includes codes, "unused-local"
  end

  # ── redundant-else ─────────────────────────────────────────────────────

  def test_redundant_else_fires_when_all_branches_return
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function sign(n: int) -> int:
          if n > 0:
              return 1
          else:
              return -1
    MT

    assert_any(warnings, "redundant-else")
  end

  def test_redundant_else_no_warn_when_branch_does_not_return
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["missing-return"])
      function sign(n: int) -> int:
          if n > 0:
              let _x = 1
          else:
              return -1
    MT

    refute_any(warnings, "redundant-else")
  end

  def test_redundant_else_no_warn_without_else
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["missing-return"])
      function sign(n: int) -> int:
          if n > 0:
              return 1
    MT

    refute_any(warnings, "redundant-else")
  end

  def test_redundant_else_multi_branch_all_return
    # if/else if both return -> else is redundant
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function classify(n: int) -> int:
          if n > 0:
              return 1
          else if n < 0:
              return -1
          else:
              return 0
    MT

    assert_any(warnings, "redundant-else")
  end

  def test_redundant_else_fires_when_branch_fatals
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["missing-return"])
      function sign(n: int) -> int:
          if n > 0:
              fatal(c"boom")
          else:
              return -1
    MT

    assert_any(warnings, "redundant-else")
  end

  # ── shadow ─────────────────────────────────────────────────────────────

  def test_shadow_warns_when_inner_redeclares_outer_name
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          let x = 1
          if true:
              let x = 2
              return x
          return x
    MT

    assert_any(warnings, "shadow")
    shadow_w = warnings.find { |w| w.code == "shadow" }
    assert_match(/'x'/, shadow_w.message)
    assert_equal 4, shadow_w.line
  end

  def test_no_shadow_in_same_scope
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          let x = 1
          return x
    MT

    refute_any(warnings, "shadow")
  end

  def test_shadow_ignores_underscore_names
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          let _x = 1
          if true:
              let _x = 2
          return 0
    MT

    refute_any(warnings, "shadow")
  end

  # ── Warning severity ──────────────────────────────────────────────────

  def test_missing_return_has_error_severity
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function compute() -> int:
          let _x = 1
    MT

    w = warnings.find { |x| x.code == "missing-return" }
    assert w, "expected missing-return warning"
    assert_equal :error, w.severity
  end

  def test_prefer_let_has_hint_severity
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          var x = 1
          return x
    MT

    w = warnings.find { |x| x.code == "prefer-let" }
    assert w, "expected prefer-let warning"
    assert_equal :hint, w.severity
  end

  def test_unused_local_has_warning_severity
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          let unused = 1
          return 0
    MT

    w = warnings.find { |x| x.code == "unused-local" }
    assert w, "expected unused-local warning"
    assert_equal :warning, w.severity
  end

  # ── ExtendingBlock linting ──────────────────────────────────────────────

  def test_lints_methods_inside_methods_block
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      struct Counter:
          value: int

      extending Counter:
          function get() -> int:
              let unused = 1
              return this.value
    MT

    assert_any(warnings, "unused-local")
    w = warnings.find { |x| x.code == "unused-local" }
    assert_match(/'unused'/, w.message)
  end

  def test_no_warnings_for_clean_method
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      struct Counter:
          value: int

      extending Counter:
          function get() -> int:
              return this.value
    MT

    assert_equal [], warnings
  end

  private

  def assert_any(warnings, code)
    assert warnings.any? { |w| w.code == code }, "expected a #{code} warning, got: #{warnings.map(&:code).inspect}"
  end

  def refute_any(warnings, code)
    refute warnings.any? { |w| w.code == code }, "expected no #{code} warning, got one"
  end
end

module LintHelpers
  def assert_any(warnings, code)
    assert warnings.any? { |w| w.code == code }, "expected a #{code} warning, got: #{warnings.map(&:code).inspect}"
  end

  def refute_any(warnings, code)
    refute warnings.any? { |w| w.code == code }, "expected no #{code} warning, got one"
  end
end

class MilkTeaLinterPlatformApiDriftTest < Minitest::Test
  include LintHelpers

  def test_warns_when_public_methods_drift_between_platform_variants
    Dir.mktmpdir("mt-lint-platform-api") do |dir|
      path = File.join(dir, "counter.mt")
      File.write(path, <<~MT)
        public struct Counter:
            value: int

        extending Counter:
            public function read() -> int:
                return this.value
      MT
      File.write(File.join(dir, "counter.windows.mt"), <<~MT)
        public struct Counter:
            value: str

        extending Counter:
            public function read() -> str:
                return this.value
      MT

      warnings = MilkTea::Linter.lint_source(File.read(path), path: path)

      warning = warnings.find { |entry| entry.code == "platform-api-drift" }
      assert warning, "expected platform-api-drift warning"
      assert_equal 5, warning.line
      assert_equal 21, warning.column
      assert_equal "read".length, warning.length
      assert_match(/counter\.windows\.mt/, warning.message)
      assert_match(/struct Counter \{ value: str \}/, warning.message)
      assert_match(/method Counter\.read\(\) -> str/, warning.message)
    end
  end

  def test_warns_with_interface_constraint_drift_in_platform_api_surface
    Dir.mktmpdir("mt-lint-platform-generic-api") do |dir|
      path = File.join(dir, "hashable.mt")
      File.write(path, <<~MT)
        public interface Named:
            function name() -> str

        public function same_key[T implements Named](left: T, right: T) -> bool:
            return true
      MT
      File.write(File.join(dir, "hashable.windows.mt"), <<~MT)
        public interface Named:
            function name() -> str

        public function same_key[T](left: T, right: T) -> bool:
            return true
      MT

      warnings = MilkTea::Linter.lint_source(File.read(path), path: path)

      warning = warnings.find { |entry| entry.code == "platform-api-drift" }
      assert warning, "expected platform-api-drift warning"
      assert_equal 4, warning.line
      assert_equal 17, warning.column
      assert_equal "same_key".length, warning.length
      assert_match(/function same_key\[T implements Named\]\(left: T, right: T\) -> bool/, warning.message)
      assert_match(/function same_key\[T\]\(left: T, right: T\) -> bool/, warning.message)
    end
  end

  def test_warns_with_platform_api_drift_anchor_at_first_export_when_current_variant_only_missing_exports
    Dir.mktmpdir("mt-lint-platform-missing-export-anchor") do |dir|
      path = File.join(dir, "service.mt")
      File.write(path, <<~MT)
        public function read() -> int:
            return 1
      MT
      File.write(File.join(dir, "service.windows.mt"), <<~MT)
        public function read() -> int:
            return 1

        public function write() -> int:
            return 2
      MT

      warnings = MilkTea::Linter.lint_source(File.read(path), path: path)

      warning = warnings.find { |entry| entry.code == "platform-api-drift" }
      assert warning, "expected platform-api-drift warning"
      assert_equal 1, warning.line
      assert_equal 17, warning.column
      assert_equal "read".length, warning.length
      assert_match(/missing 'function write\(\) -> int'/, warning.message)
    end
  end

  def test_does_not_warn_when_only_private_declarations_differ_between_variants
    Dir.mktmpdir("mt-lint-platform-private") do |dir|
      path = File.join(dir, "helpers.mt")
      File.write(path, <<~MT)
        function helper() -> int:
            return 1

        public function read() -> int:
            return helper()
      MT
      File.write(File.join(dir, "helpers.windows.mt"), <<~MT)
        function helper() -> int:
            return 2

        public function read() -> int:
            return helper()
      MT

      warnings = MilkTea::Linter.lint_source(File.read(path), path: path)

      refute_any(warnings, "platform-api-drift")
    end
  end
end

# ── Config file support ────────────────────────────────────────────────────

class MilkTeaLinterConfigTest < Minitest::Test
  include LintHelpers
  def test_config_select_limits_rules
    Dir.mktmpdir("mt-lint-config") do |dir|
      File.write(File.join(dir, ".mt-lint.yml"), "select:\n  - unused-local\n")
      path = File.join(dir, "sample.mt")
      File.write(path, <<~MT)
        function compute(x: int) -> int:
            let unused = 1
            return 0
      MT

      warnings = MilkTea::Linter.lint_source(File.read(path), path:)
      codes = warnings.map(&:code)
      assert_includes codes, "unused-local"
      refute_includes codes, "unused-param"
    end
  end

  def test_config_ignore_excludes_rules
    Dir.mktmpdir("mt-lint-config-ignore") do |dir|
      File.write(File.join(dir, ".mt-lint.yml"), "ignore:\n  - prefer-let\n")
      path = File.join(dir, "sample.mt")
      File.write(path, <<~MT)
        function main() -> int:
            var x = 1
            return x
      MT

      warnings = MilkTea::Linter.lint_source(File.read(path), path:)
      refute warnings.any? { |w| w.code == "prefer-let" }
    end
  end

  def test_config_call_override_beats_file
    # Explicit ignore= kwarg should win over what the file selects
    Dir.mktmpdir("mt-lint-config-override") do |dir|
      File.write(File.join(dir, ".mt-lint.yml"), "select:\n  - unused-local\n  - unused-param\n")
      path = File.join(dir, "sample.mt")
      File.write(path, <<~MT)
        function compute(x: int) -> int:
            let unused = 1
            return 0
      MT

      # Per-call select is nil, so config's select applies; ignore overrides
      warnings = MilkTea::Linter.lint_source(File.read(path), path:, ignore: Set["unused-local"])
      codes = warnings.map(&:code)
      refute_includes codes, "unused-local"  # suppressed by call-level ignore
      assert_includes codes, "unused-param"  # config select still active
    end
  end

  def test_no_config_file_loads_all_rules
    Dir.mktmpdir("mt-lint-no-config") do |dir|
      path = File.join(dir, "sample.mt")
      File.write(path, <<~MT)
        function compute(x: int) -> int:
            let unused = 1
            return 0
      MT

      warnings = MilkTea::Linter.lint_source(File.read(path), path:)
      codes = warnings.map(&:code)
      assert_includes codes, "unused-local"
      assert_includes codes, "unused-param"
    end
  end
end

# ── fix_source redundant-else ──────────────────────────────────────────────

class MilkTeaLinterFixRedundantElseTest < Minitest::Test
  def test_fix_source_removes_redundant_else
    source = <<~MT
      function sign(n: int) -> int:
          if n > 0:
              return 1
          else:
              return -1
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    refute_includes fixed, "else:"
    assert_includes fixed, "return -1"
    # The body should be dedented by one level
    assert_match(/^    return -1/, fixed)
  end

  def test_fix_source_leaves_necessary_else
    source = <<~MT
      function sign(n: int) -> int:
          if n > 0:
              let _x = 1
          else:
              return -1
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")
    # Not redundant — if-branch doesn't return
    assert_includes fixed, "else:"
  end

  def test_fix_source_handles_prefer_let_and_redundant_else_together
    source = <<~MT
      function classify(n: int) -> int:
          if n > 0:
              return 1
          else:
              var result = -1
              return result
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    refute_includes fixed, "else:"          # redundant else removed
    assert_includes fixed, "let result = -1" # prefer-let applied
  end
end

# ── useless-expression rule ────────────────────────────────────────────────

class MilkTeaLinterUselessExpressionTest < Minitest::Test
  include LintHelpers
  def test_warns_on_integer_literal_statement
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          42
          return 0
    MT

    w = warnings.find { |warning| warning.code == "useless-expression" }
    assert w, "expected useless-expression warning"
    assert_equal 2, w.line
    assert_equal 5, w.column
    assert_equal 2, w.length
  end

  def test_warns_on_identifier_statement_with_identifier_span
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main(argc: int) -> int:
          argc
          return 0
    MT

    w = warnings.find { |warning| warning.code == "useless-expression" }
    assert w, "expected useless-expression warning"
    assert_equal 2, w.line
    assert_equal 5, w.column
    assert_equal 4, w.length
  end

  def test_warns_on_binary_op_statement
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          1 + 2
          return 0
    MT

    assert_any warnings, "useless-expression"
  end

  def test_warns_on_string_literal_statement
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          "hello"
          return 0
    MT

    assert_any warnings, "useless-expression"
  end

  def test_no_warn_on_call_statement
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function side_effect() -> int:
          return 1

      function main() -> int:
          side_effect()
          return 0
    MT

    refute_any warnings, "useless-expression"
  end

  def test_useless_expression_has_warning_severity
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          42
          return 0
    MT

    w = warnings.find { |x| x.code == "useless-expression" }
    assert w
    assert_equal :warning, w.severity
  end
end

class MilkTeaLinterUnsafeExpressionTraversalTest < Minitest::Test
  def test_param_use_inside_unsafe_expression_counts_as_used
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main(value: ptr[int]) -> int:
          let result = unsafe: read(value)
          return result
    MT

    refute warnings.any? { |warning| warning.code == "unused-param" && warning.symbol_name == "value" }
  end
end

# ── fix_source: unused-import + dead-assignment ────────────────────────────

class MilkTeaLinterFixUnusedImportDeadAssignmentTest < Minitest::Test
  def test_fix_source_removes_unused_import
    source = <<~MT
      import demo.other

      function main() -> int:
          return 0
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    refute_match(/import demo\.other/, fixed)
  end

  def test_fix_source_keeps_used_import
    source = <<~MT
      import demo.other

      function main() -> int:
          let x: other.Value = other.Value.new()
          return 0
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    assert_match(/import demo\.other/, fixed)
  end

  def test_fix_source_removes_dead_assignment
    source = <<~MT
      function compute(n: int) -> int:
          let result = n + 1
          result = n + 2
          return result
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    # The dead `result = n + 1` reassignment should be removed
    # (The first `let result = n + 1` is the declaration; the second is the dead write)
    lines = fixed.lines.map(&:rstrip).reject(&:empty?)
    assignments = lines.select { |l| l.match?(/result\s*=/) }
    # The dead intermediate assignment is removed
    refute assignments.any? { |l| l.match?(/\A\s*result\s*=\s*n\s*\+\s*1/) && !l.match?(/let/) }
  end

  def test_fix_source_does_not_remove_let_declaration
    source = <<~MT
      function compute(n: int) -> int:
          let result = n + 1
          return result
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    # let declarations are never touched by dead-assignment fixer
    assert_includes fixed, "let result = n + 1"
  end
end

# ── self-assignment ────────────────────────────────────────────────────────

class MilkTeaLinterSelfAssignmentTest < Minitest::Test
  def test_warns_on_self_assignment
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          var x: int = 1
          x = x
          return x
    MT

    w = warnings.find { |w| w.code == "self-assignment" }
    assert w, "expected self-assignment warning"
    assert_equal 3, w.line
    assert_equal 5, w.column
    assert_equal 1, w.length
    assert_match(/'x'/, w.message)
  end

  def test_no_warn_on_normal_assignment
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          var x: int = 1
          var y: int = 2
          x = y
          return x
    MT

    refute warnings.any? { |w| w.code == "self-assignment" }
  end

  def test_no_warn_on_compound_self_assignment
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          var x: int = 1
          x += x
          return x
    MT

    refute warnings.any? { |w| w.code == "self-assignment" }
  end
end

# ── self-comparison ────────────────────────────────────────────────────────

class MilkTeaLinterSelfComparisonTest < Minitest::Test
  def test_warns_on_self_equal_comparison
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main(x: int) -> int:
          if x == x:
              return 1
          return 0
    MT

    w = warnings.find { |w| w.code == "self-comparison" }
    assert w, "expected self-comparison warning"
    assert_equal 2, w.line
    assert_equal 8, w.column
    assert_equal 6, w.length
    assert_match(/'x'/, w.message)
    assert_match(/always true/, w.message)
  end

  def test_warns_on_self_not_equal_comparison
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main(x: int) -> int:
          if x != x:
              return 1
          return 0
    MT

    w = warnings.find { |w| w.code == "self-comparison" }
    assert w, "expected self-comparison warning"
    assert_match(/always false/, w.message)
  end

  def test_no_warn_on_different_operands
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main(x: int, y: int) -> int:
          if x == y:
              return 1
          return 0
    MT

    refute warnings.any? { |w| w.code == "self-comparison" }
  end
end

# ── constant-condition ─────────────────────────────────────────────────────

class MilkTeaLinterConstantConditionTest < Minitest::Test
  def test_warns_on_literal_true_in_if
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["redundant-else"])
      function main() -> int:
          if true:
              return 1
          else:
              return 0
    MT

    w = warnings.find { |w| w.code == "constant-condition" }
    assert w, "expected constant-condition warning"
    assert_match(/always true/, w.message)
    assert_equal 2, w.line
    assert_equal 8, w.column
    assert_equal 4, w.length
  end

  def test_warns_on_literal_false_in_if
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          if false:
              return 1
          return 0
    MT

    w = warnings.find { |w| w.code == "constant-condition" }
    assert w, "expected constant-condition warning"
    assert_match(/always false/, w.message)
    assert_equal 8, w.column
    assert_equal 5, w.length
  end

  def test_warns_on_literal_false_in_while
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          while false:
              let _x = 1
          return 0
    MT

    w = warnings.find { |w| w.code == "constant-condition" }
    assert w, "expected constant-condition warning"
    assert_match(/always false/, w.message)
    assert_equal 2, w.line
    assert_equal 11, w.column
    assert_equal 5, w.length
  end

  def test_no_warn_on_while_true
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          while true:
              return 42
    MT

    refute warnings.any? { |w| w.code == "constant-condition" }
  end

  def test_warns_on_cp_constant_variable_in_if
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["unused-local", "prefer-let"])
      function main() -> int:
          var flag: bool = true
          if flag:
              return 1
          return 0
    MT

    w = warnings.find { |w| w.code == "constant-condition" }
    assert w, "expected constant-condition warning via CP"
    assert_match(/always true/, w.message)
  end

  def test_no_warn_on_runtime_variable
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main(flag: bool) -> int:
          if flag:
              return 1
          return 0
    MT

    refute warnings.any? { |w| w.code == "constant-condition" }
  end

  def test_no_constant_condition_or_prefer_let_after_inout_call
    source = <<~MT
      import std.sample as sample

      function main() -> int:
          var tab_active: int = 0
          sample.tab_bar(tab_active)
          if tab_active == 0:
              return 1
          else if tab_active == 1:
              return 2
          return 3
    MT

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "std", "c"))
      File.write(File.join(dir, "std", "c", "sample.mt"), <<~MT)
        external

        external function TabBar(active: ptr[int]) -> void
      MT
      File.write(File.join(dir, "std", "sample.mt"), <<~MT)
        import std.c.sample as c

        public foreign function tab_bar(inout active: int) -> void = c.TabBar
      MT

      path = File.join(dir, "demo.mt")
      File.write(path, source)

      warnings = MilkTea::Linter.lint_source(
        source,
        path:,
        ignore: Set["unused-local"]
      )

      refute warnings.any? { |w| w.code == "constant-condition" }
      refute warnings.any? { |w| w.code == "prefer-let" && w.symbol_name == "tab_active" }
    end
  end

  def test_no_constant_condition_or_prefer_let_after_ptr_of_ref_of_call
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["unused-local"])
      function mutate(value: ptr[int]) -> void:
          return

      function main() -> int:
          var device_count: int = 0
          mutate(ptr_of(device_count))
          if device_count == 0:
              return 1
          return 2
    MT

    refute warnings.any? { |w| w.code == "constant-condition" }
    refute warnings.any? { |w| w.code == "prefer-let" && w.symbol_name == "device_count" }
  end

  def test_no_warn_on_while_counter_decrement
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["unused-local", "prefer-let"])
      function main() -> int:
          var index = 3
          while index > 0:
              index -= 1
          return index
    MT

    refute warnings.any? { |w| w.code == "constant-condition" }
  end

  def test_constant_condition_while_reports_condition_span
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          while false:
              return 1
          return 0
    MT

    w = warnings.find { |warning| warning.code == "constant-condition" }
    assert w, "expected constant-condition warning"
    assert_equal 2, w.line
    assert_equal 11, w.column
    assert_equal 5, w.length
    assert_equal "false", w.symbol_name
  end
end

# ── redundant-null-check ───────────────────────────────────────────────────

class MilkTeaLinterRedundantNullCheckTest < Minitest::Test
  def test_warns_on_redundant_null_check_inside_non_null_branch
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["unused-local"])
      function process(x: int?) -> int:
          if x != null:
              if x != null:
                  let _v = 1
              return 1
          return 0
    MT

    w = warnings.find { |w| w.code == "redundant-null-check" }
    assert w, "expected redundant-null-check warning"
    assert_equal 3, w.line
    assert_equal 12, w.column
    assert_equal 9, w.length
    assert_match(/'x'/, w.message)
    assert_equal :hint, w.severity
  end

  def test_no_warn_on_first_null_check
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["unused-local"])
      function process(x: int?) -> int:
          if x != null:
              let _v = 1
              return 1
          return 0
    MT

    refute warnings.any? { |w| w.code == "redundant-null-check" }
  end
end

# ── redundant-read-cast ──────────────────────────────────────────────────

class MilkTeaLinterRedundantReadCastTest < Minitest::Test
  private def lint_with_sema(source, path: "demo.mt", **kwargs)
    ast = MilkTea::Parser.parse(source, path: path)
    analysis = MilkTea::Sema.check(ast, imported_modules: {})
    MilkTea::Linter.lint_source(source, path: path, sema_facts: analysis, **kwargs)
  end

  def test_warns_on_redundant_read_cast_after_fatal_guard
    warnings = lint_with_sema(<<~MT, path: "demo.mt")
      function maybe_handle(handle: ptr[int]?) -> ptr[int]?:
          return handle

      function main(handle: ptr[int]?) -> int:
          let value_ptr = maybe_handle(handle)
          if value_ptr == null:
              fatal("missing")
          unsafe:
              return read(ptr[int]<-value_ptr)
    MT

    warning = warnings.find { |w| w.code == "redundant-read-cast" }
    assert warning, "expected redundant-read-cast warning"
    assert_equal 9, warning.line
    assert_equal :hint, warning.severity
  end

  def test_does_not_warn_without_non_null_proof
    warnings = lint_with_sema(<<~MT, path: "demo.mt")
      function main(handle: ptr[int]?) -> int:
          unsafe:
              return read(ptr[int]<-handle)
    MT

    refute warnings.any? { |w| w.code == "redundant-read-cast" }
  end

  def test_explicit_nil_sema_facts_suppresses_redundant_cast
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", sema_facts: nil, unresolved_import_paths: [])
      function main() -> int:
          return int<-42
    MT

    refute warnings.any? { |w| w.code == "redundant-cast" }
  end

  def test_fix_source_removes_redundant_read_cast
    source = <<~MT
      function maybe_handle(handle: ptr[int]?) -> ptr[int]?:
          return handle

      function main(handle: ptr[int]?) -> int:
          let value_ptr = maybe_handle(handle)
          if value_ptr == null:
              fatal("missing")
          unsafe:
              return read(ptr[int]<-value_ptr)
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    assert_includes fixed, "return read(value_ptr)"
    refute_includes fixed, "read(ptr[int]<-value_ptr)"

    analysis = MilkTea::Sema.check(MilkTea::Parser.parse(fixed, path: "demo.mt"), imported_modules: {})
    assert_equal true, analysis.functions.key?("main")
  end
end

# ── redundant-cast ───────────────────────────────────────────────────────

class MilkTeaLinterRedundantCastTest < Minitest::Test
  def test_warns_on_redundant_numeric_literal_cast_in_comparison
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function is_ascii_space(ch: ubyte) -> bool:
          return ch == ubyte<-32 or ch == ubyte<-9
    MT

    redundant_casts = warnings.select { |warning| warning.code == "redundant-cast" }
    assert_equal 2, redundant_casts.length
    assert_equal [2, 2], redundant_casts.map(&:line)
    assert_equal :hint, redundant_casts.first.severity
  end

  def test_warns_on_redundant_return_cast_when_function_return_type_matches
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function widen(value: int) -> long:
          return long<-value
    MT

    assert warnings.any? { |warning| warning.code == "redundant-cast" }
  end

  def test_warns_on_redundant_typed_local_cast
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function widen(value: int) -> long:
          let widened: long = long<-value
          return widened
    MT

    assert warnings.any? { |warning| warning.code == "redundant-cast" }
  end

  def test_warns_on_redundant_call_argument_cast
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function takes_long(value: long) -> long:
          return value

      function main(value: int) -> long:
          return takes_long(long<-value)
    MT

    assert warnings.any? { |warning| warning.code == "redundant-cast" }
  end

  def test_warns_on_redundant_lossless_local_int_to_float_cast
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main(value: int) -> int:
          let widened: float = float<-value
          return 0
    MT

    assert warnings.any? { |warning| warning.code == "redundant-cast" }
  end

  def test_does_not_warn_on_required_call_argument_cast
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function takes_offset(offset: ptr_int) -> ptr_int:
          return offset

      function main(offset: ptr_uint) -> ptr_int:
          return takes_offset(ptr_int<-offset)
    MT

    refute warnings.any? { |warning| warning.code == "redundant-cast" }
  end

  def test_does_not_warn_on_required_lossy_external_float_argument_cast
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      external function set_scale(value: float) -> void

      function main(channel: int) -> int:
          set_scale(float<-channel)
          return 0
    MT

    refute warnings.any? { |warning| warning.code == "redundant-cast" }
  end

  def test_does_not_warn_on_inferred_local_cast_that_changes_binding_type
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function widen(value: int) -> long:
          let widened = long<-value
          return widened
    MT

    refute warnings.any? { |warning| warning.code == "redundant-cast" }
  end

  def test_fix_source_removes_redundant_casts
    source = <<~MT
      function is_ascii_space(ch: ubyte) -> bool:
          return ch == ubyte<-32 or ch == ubyte<-9
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    assert_includes fixed, "return ch == 32 or ch == 9"
    refute_includes fixed, "ubyte<-32"
    refute_includes fixed, "ubyte<-9"

    analysis = MilkTea::Sema.check(MilkTea::Parser.parse(fixed, path: "demo.mt"), imported_modules: {})
    assert_equal true, analysis.functions.key?("is_ascii_space")
  end

  def test_fix_source_keeps_required_call_argument_cast
    source = <<~MT
      function takes_offset(offset: ptr_int) -> ptr_int:
          return offset

      function main(offset: ptr_uint) -> ptr_int:
          return takes_offset(ptr_int<-offset)
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    assert_equal source, fixed
  end

  def test_redundant_cast_scan_ignores_heredoc_openers
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      const QUERY: cstr = c<<-SQL
      SELECT 1
      SQL

      function is_ascii_space(ch: ubyte) -> bool:
          return ch == ubyte<-32
    MT

    redundant_casts = warnings.select { |warning| warning.code == "redundant-cast" }
    assert_equal 1, redundant_casts.length
    assert_equal 6, redundant_casts.first.line
  end
end

# ── redundant-read-release-temp ─────────────────────────────────────────

class MilkTeaLinterRedundantReadReleaseTempTest < Minitest::Test
  def test_warns_on_read_temp_only_used_for_release
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      struct Box:
          value: int

      extending Box:
          mutable function release() -> void:
              pass

      function main(box_ptr: ptr[Box]) -> void:
          unsafe:
              var owned = read(box_ptr)
              owned.release()
    MT

    warning = warnings.find { |w| w.code == "redundant-read-release-temp" }
    assert warning, "expected redundant-read-release-temp warning"
    assert_equal 10, warning.line
    assert_equal :hint, warning.severity
  end

  def test_does_not_warn_when_temp_is_used_after_release
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      struct Box:
          value: int

      extending Box:
          mutable function release() -> void:
              pass

      function main(box_ptr: ptr[Box]) -> int:
          unsafe:
              var owned = read(box_ptr)
              owned.release()
              return owned.value
    MT

    refute warnings.any? { |w| w.code == "redundant-read-release-temp" }
  end

  def test_fix_source_inlines_read_release_temp
    source = <<~MT
      struct Box:
          value: int

      extending Box:
          mutable function release() -> void:
              pass

      function main(box_ptr: ptr[Box]) -> void:
          unsafe:
              var owned = read(box_ptr)
              owned.release()
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    assert_includes fixed, "read(box_ptr).release()"
    refute_includes fixed, "var owned = read(box_ptr)"
    refute_includes fixed, "owned.release()"
  end
end

# ── prefer-let-else ─────────────────────────────────────────────────────

class MilkTeaLinterPreferLetElseTest < Minitest::Test
  private def lint_with_sema(source, path: "demo.mt", **kwargs)
    ast = MilkTea::Parser.parse(source, path: path)
    analysis = MilkTea::Sema.check(ast, imported_modules: {})
    MilkTea::Linter.lint_source(source, path: path, sema_facts: analysis, **kwargs)
  end

  def test_warns_on_immediate_nullable_guard_return
    warnings = lint_with_sema(<<~MT, path: "demo.mt")
      function maybe_handle(handle: ptr[int]?) -> ptr[int]?:
          return handle

      function main(handle: ptr[int]?) -> int:
          let value_ptr = maybe_handle(handle)
          if value_ptr == null:
              return 0
          unsafe:
              return read(value_ptr)
    MT

    warning = warnings.find { |w| w.code == "prefer-let-else" }
    assert warning, "expected prefer-let-else warning"
    assert_equal 6, warning.line
    assert_equal :hint, warning.severity
  end

  def test_does_not_warn_when_declaration_has_explicit_type
    warnings = lint_with_sema(<<~MT, path: "demo.mt")
      function maybe_handle(handle: ptr[int]?) -> ptr[int]?:
          return handle

      function main(handle: ptr[int]?) -> int:
          let value_ptr: ptr[int]? = maybe_handle(handle)
          if value_ptr == null:
              return 0
          unsafe:
              return read(value_ptr)
    MT

    refute warnings.any? { |w| w.code == "prefer-let-else" }
  end

  def test_fix_source_rewrites_nullable_guard_as_let_else
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

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    assert_includes fixed, "let value_ptr = maybe_handle(handle) else:"
    refute_includes fixed, "if value_ptr == null:"
  end

  def test_warns_on_generic_method_nullable_guard_without_binding_metadata
    warnings = lint_with_sema(<<~MT, path: "demo.mt")
      struct Node[T]:
          value: T
          next: ptr[Node[T]]?

      public struct Values[T]:
          node: ptr[Node[T]]?

      extending Values[T]:
          public mutable function next() -> const_ptr[T]?:
              let current = this.node
              if current == null:
                  return null

              unsafe:
                  let current_ptr = ptr[Node[T]]<-current
                  this.node = read(current_ptr).next
                  return const_ptr_of(read(current_ptr).value)
    MT

    warning = warnings.find { |w| w.code == "prefer-let-else" }
    assert warning, "expected prefer-let-else warning for generic method"
    assert_equal 11, warning.line
    assert_equal :hint, warning.severity
  end

  def test_fix_source_rewrites_generic_method_nullable_guard_as_let_else
    source = <<~MT
      struct Node[T]:
          value: T
          next: ptr[Node[T]]?

      public struct Values[T]:
          node: ptr[Node[T]]?

      extending Values[T]:
          public mutable function next() -> const_ptr[T]?:
              let current = this.node
              if current == null:
                  return null

              unsafe:
                  let current_ptr = ptr[Node[T]]<-current
                  this.node = read(current_ptr).next
                  return const_ptr_of(read(current_ptr).value)
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    assert_includes fixed, "let current = this.node else:"
    refute_includes fixed, "if current == null:"
  end
end

# ── directional-ffi-arg ──────────────────────────────────────────────────

class MilkTeaLinterDirectionalFfiArgTest < Minitest::Test
  def test_warns_on_ptr_of_for_directional_ffi_param
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      external function fill(out value: int) -> void

      function main() -> int:
          var value = 0
          fill(ptr_of(value))
          return value
    MT

    warning = warnings.find { |w| w.code == "directional-ffi-arg" }
    assert warning, "expected directional-ffi-arg warning"
    assert_equal 5, warning.line
    assert_equal :hint, warning.severity
  end

  def test_warns_on_legacy_out_keyword_for_directional_ffi_param
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      external function fill(out value: int) -> void

      function main() -> int:
          var value = 0
          fill(out value)
          return value
    MT

    warning = warnings.find { |w| w.code == "directional-ffi-arg" }
    assert warning, "expected directional-ffi-arg warning"
    assert_equal 5, warning.line
  end

  def test_does_not_warn_on_plain_lvalue_for_directional_ffi_param
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      external function fill(out value: int) -> void

      function main() -> int:
          var value = 0
          fill(value)
          return value
    MT

    refute warnings.any? { |w| w.code == "directional-ffi-arg" }
  end

  def test_fix_source_removes_ptr_of_wrapper_for_directional_ffi_param
    source = <<~MT
      external function fill(out value: int) -> void

      function main() -> int:
          var value = 0
          fill(ptr_of(value))
          return value
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    assert_includes fixed, "fill(value)"
    refute_includes fixed, "fill(ptr_of(value))"
  end

  def test_fix_source_removes_out_keyword_for_directional_ffi_param
    source = <<~MT
      external function fill(out value: int) -> void

      function main() -> int:
          var value = 0
          fill(out value)
          return value
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    assert_includes fixed, "fill(value)"
    refute_includes fixed, "fill(out value)"
  end
end

# ── redundant-unsafe ─────────────────────────────────────────────────────

class MilkTeaLinterRedundantUnsafeTest < Minitest::Test
  private def lint_with_sema(source, path: "demo.mt", **kwargs)
    ast = MilkTea::Parser.parse(source, path: path)
    analysis = MilkTea::Sema.check(ast, imported_modules: {})
    MilkTea::Linter.lint_source(source, path: path, sema_facts: analysis, **kwargs)
  end

  def test_warns_on_redundant_unsafe_block
    warnings = lint_with_sema(<<~MT, path: "demo.mt", ignore: Set["unused-local"])
      function main(value: int) -> int:
          unsafe:
              let copy = value + 1
          return value
    MT

    warning = warnings.find { |w| w.code == "redundant-unsafe" }
    assert warning, "expected redundant-unsafe warning"
    assert_equal 2, warning.line
    assert_equal :hint, warning.severity
  end

  def test_does_not_warn_when_unsafe_block_dereferences_raw_pointer
    warnings = lint_with_sema(<<~MT, path: "demo.mt")
      function main(value: ptr[int]) -> int:
          unsafe:
              return read(value)
    MT

    refute warnings.any? { |w| w.code == "redundant-unsafe" }
  end

  def test_warns_on_outer_unsafe_when_only_nested_unsafe_is_needed
    warnings = lint_with_sema(<<~MT, path: "demo.mt")
      function main(value: ptr[int]) -> int:
          unsafe:
              unsafe:
                  return read(value)
    MT

    redundant = warnings.select { |w| w.code == "redundant-unsafe" }
    assert_equal 1, redundant.length
    assert_equal 2, redundant.first.line
  end

  def test_warns_on_redundant_inline_unsafe_expression
    warnings = lint_with_sema(<<~MT, path: "demo.mt")
      function main() -> ptr[int]:
          var value: int = 0
          return unsafe: ptr[int]<-ptr_of(value)
    MT

    warning = warnings.find { |w| w.code == "redundant-unsafe" }
    assert warning, "expected redundant-unsafe warning"
    assert_equal 3, warning.line
    assert_equal 12, warning.column
    assert_equal :hint, warning.severity
  end

  def test_profile_records_redundant_unsafe_recheck_phases
    profile = MilkTea::Linter::Profile.new

    warnings = lint_with_sema(<<~MT, path: "demo.mt", profile:)
      function main() -> ptr[int]:
          var value: int = 0
          return unsafe: ptr[int]<-ptr_of(value)
    MT

    assert warnings.any? { |warning| warning.code == "redundant-unsafe" }
    assert_includes profile.timings_ms.keys, "rule.redundant_unsafe"
    assert_includes profile.timings_ms.keys, "redundant_unsafe_recheck.sema"
    assert_includes profile.timings_ms.keys, "redundant_unsafe_baseline.sema"
    assert_operator profile.counts.fetch("redundant_unsafe_recheck.sema", 0), :>=, 1
    assert_includes profile.summary(limit: 20), "redundant_unsafe_recheck.sema"
  end

  def test_fast_lint_tier_skips_expensive_recheck_rules
    warnings = lint_with_sema(<<~MT, path: "demo.mt", lint_tier: :fast, ignore: Set["unused-local"])
      function main(value: int) -> int:
          unsafe:
              let copy = value + 1
          return int<-value
    MT

    codes = warnings.map(&:code)
    refute_includes codes, "redundant-unsafe"
    refute_includes codes, "redundant-cast"
  end

  def test_profile_reuses_shared_flow_analyses_across_rules
    profile = MilkTea::Linter::Profile.new

    warnings = lint_with_sema(<<~MT, path: "demo.mt", profile:, ignore: Set["unused-local", "prefer-let"])
      function main(handle: ptr[int]?) -> int:
          var copy = 0
          if true:
              copy = 1
          let value_ptr = handle
          if value_ptr == null:
              fatal("missing")
          unsafe:
              return read(ptr[int]<-value_ptr)
    MT

    assert warnings.any? { |warning| warning.code == "constant-condition" }
    assert warnings.any? { |warning| warning.code == "redundant-read-cast" }
    assert_equal 1, profile.counts.fetch("flow.graph", 0)
    assert_equal 1, profile.counts.fetch("flow.reachability", 0)
    assert_equal 1, profile.counts.fetch("flow.nullability", 0)
    assert_equal 1, profile.counts.fetch("flow.constant_propagation", 0)
    assert_equal 1, profile.counts.fetch("dead_assignment.graph", 0)
    assert_equal 1, profile.counts.fetch("dead_assignment.liveness", 0)
  end

  def test_warns_on_redundant_inline_unsafe_expression_even_with_unrelated_later_error
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> ptr[int]:
          var value: int = 0
          let pointer = unsafe: ptr[int]<-ptr_of(value)
          let broken = unsafe: read(ptr[int]<-0)
          return pointer
    MT

    warning = warnings.find { |w| w.code == "redundant-unsafe" && w.line == 3 }
    assert warning, "expected redundant-unsafe warning"
    assert_equal 19, warning.column
  end

  def test_does_not_warn_on_generic_method_unsafe_block_with_pointer_cast
    warnings = lint_with_sema(<<~MT, path: "demo.mt")
      struct Box[T]:
          data: ptr[T]

      extending Box[T]:
          mutable function load(index: ptr_uint) -> T:
              unsafe:
                  let item = ptr[T]<-this.data + index
                  return read(item)
    MT

    refute warnings.any? { |w| w.code == "redundant-unsafe" }
  end

  def test_warns_on_redundant_generic_method_unsafe_block_without_builtin_unsafe_syntax
    warnings = lint_with_sema(<<~MT, path: "demo.mt")
      struct Box[T]:
          value: T

      extending Box[T]:
          function copy() -> T:
              unsafe:
                  return this.value
    MT

    warning = warnings.find { |w| w.code == "redundant-unsafe" }
    assert warning, "expected redundant-unsafe warning"
    assert_equal 6, warning.line
  end

  def test_warns_on_redundant_unsafe_block_with_shadowed_read_after_partial_sema_failure
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["unused-local", "prefer-let"])
      function read(value: int) -> int:
          return value

      function main(value: int) -> int:
          unsafe:
              let broken = missing
              return read(value)
    MT

    warning = warnings.find { |w| w.code == "redundant-unsafe" }
    assert warning, "expected redundant-unsafe warning"
    assert_equal 5, warning.line
  end

  def test_does_not_warn_on_builtin_reinterpret_after_partial_sema_failure_even_when_name_is_shadowed
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["unused-local", "prefer-let"])
      function reinterpret[T](value: T) -> T:
          return value

      function main(value: uint) -> uint:
          unsafe:
              let broken = missing
              return reinterpret[uint](value)
    MT

    refute warnings.any? { |w| w.code == "redundant-unsafe" }
  end

  def test_does_not_warn_on_builtin_pointer_cast_after_partial_sema_failure_even_when_name_is_shadowed
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["unused-local", "prefer-let"])
      function cast(value: int) -> int:
          return value

      function main(value: int) -> ptr[int]:
          unsafe:
              let broken = missing
              return ptr[int]<-ptr_of(value)
    MT

    refute warnings.any? { |w| w.code == "redundant-unsafe" }
  end

  def test_fix_source_removes_redundant_unsafe_block
    source = <<~MT
      function main(value: int) -> int:
          unsafe:
              let copy = value + 1
          return value
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")
    refute_match(/unsafe:/, fixed)
    assert_match(/\n    let copy = value \+ 1\n/, fixed)
  end

  def test_fix_source_removes_redundant_inline_unsafe_expression
    source = <<~MT
      function main() -> ptr[int]:
          var value: int = 0
          return unsafe: ptr[int]<-ptr_of(value)
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    assert_includes fixed, "return ptr[int]<-ptr_of(value)"
    refute_includes fixed, "return unsafe: ptr[int]<-ptr_of(value)"
  end
end

class MilkTeaLinterRedundantReturnTest < Minitest::Test
  def test_warns_on_final_bare_return_in_void_function
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> void:
          let _ = 1
          return
    MT

    warning = warnings.find { |w| w.code == "redundant-return" }
    assert warning, "expected redundant-return warning"
    assert_equal 3, warning.line
    assert_equal 5, warning.column
    assert_equal :hint, warning.severity
  end

  def test_fix_source_removes_final_bare_return_in_void_function
    source = <<~MT
      function main() -> void:
          let _ = 1
          return
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    assert_includes fixed, "let _ = 1"
    refute_includes fixed, "\n    return\n"
  end
end

# ── loop-single-iteration ──────────────────────────────────────────────────

class MilkTeaLinterLoopSingleIterationTest < Minitest::Test
  def test_warns_on_while_loop_that_always_breaks
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["constant-condition"])
      function main() -> int:
          var result: int = 0
          while true:
              result = 1
              break
          return result
    MT

    w = warnings.find { |w| w.code == "loop-single-iteration" }
    assert w, "expected loop-single-iteration warning"
    assert_equal 3, w.line
    assert_equal 5, w.column
    assert_equal 5, w.length
  end

  def test_warns_on_while_loop_that_always_returns
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["missing-return", "constant-condition"])
      function find() -> int:
          while true:
              return 42
    MT

    w = warnings.find { |w| w.code == "loop-single-iteration" }
    assert w, "expected loop-single-iteration warning"
  end

  def test_no_warn_on_normal_loop
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      function main() -> int:
          var i: int = 0
          while i < 10:
              i = i + 1
          return i
    MT

    refute warnings.any? { |w| w.code == "loop-single-iteration" }
  end
end
