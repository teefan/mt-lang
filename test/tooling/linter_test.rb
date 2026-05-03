# frozen_string_literal: true

require_relative "../test_helper"

class MilkTeaLinterTest < Minitest::Test
  def test_reports_unused_local_with_line_number
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          let unused = 1
          return 0
    MT

    assert_equal 1, warnings.length
    warning = warnings.first
    assert_equal "demo.mt", warning.path
    assert_equal 4, warning.line
    assert_equal "unused-local", warning.code
    assert_match(/unused local 'unused'/, warning.message)
  end

  def test_does_not_report_used_local
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          let used = 1
          return used
    MT

    assert_equal [], warnings
  end

  def test_reports_only_shadowed_unused_binding
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["constant-condition"])
      module demo.lint

      def main() -> i32:
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
    warnings.each { |w| assert_equal 6, w.line }
  end

  def test_ignores_intentionally_discarded_locals
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          let _unused = 1
          return 0
    MT

    assert_equal [], warnings
  end

  def test_counts_compound_assignment_as_use
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          var total = 1
          total += 2
          return total
    MT

    assert_equal [], warnings
  end

  # ── unused-param ────────────────────────────────────────────────────

  def test_reports_unused_param
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def add(a: i32, b: i32) -> i32:
          return a
    MT

    assert_equal 1, warnings.length
    w = warnings.first
    assert_equal "unused-param", w.code
    assert_match(/unused parameter 'b'/, w.message)
    assert_equal 3, w.line
  end

  def test_does_not_report_used_param
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def add(a: i32, b: i32) -> i32:
          return a + b
    MT

    assert_equal [], warnings
  end

  def test_ignores_underscore_param
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def callback(_event: i32) -> i32:
          return 0
    MT

    assert_equal [], warnings
  end

  # ── prefer-let ──────────────────────────────────────────────────────

  def test_prefer_let_for_var_never_reassigned
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          var value = 42
          return value
    MT

    assert_equal 1, warnings.length
    w = warnings.first
    assert_equal "prefer-let", w.code
    assert_match(/never reassigned/, w.message)
    assert_match(/'value'/, w.message)
    assert_equal 4, w.line
  end

  def test_no_prefer_let_when_var_is_reassigned
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          var counter = 0
          counter = counter + 1
          return counter
    MT

    assert_equal [], warnings
  end

  def test_no_prefer_let_for_let_locals
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          let value = 42
          return value
    MT

    assert_equal [], warnings
  end

  # ── unreachable-code ────────────────────────────────────────────────

  def test_unreachable_code_after_return
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          return 0
          let dead = 1
    MT

    assert_equal 1, warnings.length
    w = warnings.first
    assert_equal "unreachable-code", w.code
    assert_match(/unreachable/, w.message)
    assert_equal 5, w.line
  end

  def test_no_unreachable_before_return
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          let x = 1
          return x
    MT

    assert_equal [], warnings
  end

  def test_unreachable_after_all_branches_terminate
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["missing-return"])
      module demo.lint

      def main(flag: bool) -> i32:
          if flag:
              return 1
          else:
              return 2
          let dead = 3
    MT

    unreachable = warnings.select { |w| w.code == "unreachable-code" }
    assert_equal 1, unreachable.length
    assert_equal 8, unreachable.first.line
  end

  # ── borrow-and-mutate ────────────────────────────────────────────────

  def test_borrow_and_mutate_warns_on_aliasing
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint
      import std.mem

      def foo(n: i32) -> i32:
          var x: i32 = n
          let p = ref_of(x)
          x = 42
          return read(p)
    MT

    borrow = warnings.select { |w| w.code == "borrow-and-mutate" }
    refute_empty borrow
    assert_match(/x/, borrow.first.message)
  end

  def test_no_borrow_warn_when_no_write_after_borrow
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint
      import std.mem

      def foo(n: i32) -> i32:
          var x: i32 = n
          let p = ref_of(x)
          return read(p)
    MT

    borrow = warnings.select { |w| w.code == "borrow-and-mutate" }
    assert_empty borrow
  end

  # ── unused-import ────────────────────────────────────────────────────

  def test_reports_unused_import
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint
      import std.vec

      def main() -> i32:
          return 0
    MT

    assert_equal 1, warnings.length
    w = warnings.first
    assert_equal "unused-import", w.code
    assert_match(/unused import 'vec'/, w.message)
    assert_equal 2, w.line
  end

  def test_does_not_report_import_used_in_expression
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint
      import std.vec

      def main() -> i32:
          let _v = vec.new()
          return 0
    MT

    assert_equal [], warnings
  end

  def test_does_not_report_import_used_as_type_ref
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint
      import std.vec

      def process(_v: vec.Vec[i32, 4]) -> i32:
          return 0
    MT

    assert_equal [], warnings
  end

  def test_import_with_alias_uses_alias_name
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint
      import std.vec as v

      def main() -> i32:
          return 0
    MT

    assert_equal 1, warnings.length
    w = warnings.first
    assert_equal "unused-import", w.code
    assert_match(/unused import 'v'/, w.message)
  end

  # ── dead-assignment ────────────────────────────────────────────────────

  def test_dead_assignment_value_overwritten
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          var x = 1
          x = 2
          return x
    MT

    assert_equal 1, warnings.length
    w = warnings.first
    assert_equal "dead-assignment", w.code
    assert_match(/'x'/, w.message)
    assert_equal 4, w.line
  end

  def test_no_dead_assignment_when_value_is_read
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          var x = 1
          let _y = x
          x = 2
          return x
    MT

    assert_equal [], warnings
  end

  def test_dead_assignment_write_only_tail
    # x is read once, then overwritten and the last write is never read
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          var x = 1
          let _y = x
          x = 2
          return 0
    MT

    assert_equal 1, warnings.length
    assert_equal "dead-assignment", warnings.first.code
    assert_equal 6, warnings.first.line
  end

  def test_no_dead_assignment_when_never_assigned_initial_value
    # Declaration without value then immediate use
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          var x: i32
          x = 5
          return x
    MT

    assert_equal [], warnings
  end

  def test_no_dead_assignment_for_unused_local
    # unused-local should fire, not dead-assignment
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          let unused = 1
          return 0
    MT

    codes = warnings.map(&:code)
    assert_includes codes, "unused-local"
    refute_includes codes, "dead-assignment"
  end

  def test_no_dead_assignment_for_while_counter_backedge_read
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          var index: i32 = 0
          while index < 3:
              index += 1
          return index
    MT

    refute warnings.any? { |w| w.code == "dead-assignment" }
  end

  def test_no_dead_assignment_for_conditional_overwrite
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main(cond: bool) -> i32:
          var count: i32 = 0
          if cond:
              count = 1
          return count
    MT

    refute warnings.any? { |w| w.code == "dead-assignment" }
  end

  def test_dead_assignment_when_overwritten_on_all_paths
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main(cond: bool) -> i32:
          var x: i32 = 0
          if cond:
              x = 1
          else:
              x = 2
          x = 3
          return x
    MT

    dead = warnings.select { |w| w.code == "dead-assignment" }
    assert_equal 3, dead.length
    lines = dead.map(&:line).sort
    assert_equal [4, 6, 8], lines
  end

  # ── fix_source ─────────────────────────────────────────────────────────

  def test_fix_source_converts_prefer_let
    source = <<~MT
      module demo.fix

      def main() -> i32:
          var x = 1
          return x
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    assert_includes fixed, "let x = 1"
    refute_includes fixed, "var x = 1"
  end

  def test_fix_source_leaves_legitimately_mutable_var
    source = <<~MT
      module demo.fix

      def main() -> i32:
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
      module demo.fix

      def main() -> i32:
          let x = 1
          return x
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")
    assert_equal source, fixed
  end

  # ── missing-return ─────────────────────────────────────────────────────

  def test_missing_return_warns_when_no_return
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def compute() -> i32:
          let _x = 1
    MT

    assert_equal 1, warnings.length
    w = warnings.first
    assert_equal "missing-return", w.code
    assert_match(/compute/, w.message)
    assert_equal 3, w.line
  end

  def test_missing_return_no_warn_when_always_returns
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def compute() -> i32:
          return 42
    MT

    refute_any(warnings, "missing-return")
  end

  def test_missing_return_no_warn_for_void_function
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def setup():
          let _x = 1
    MT

    assert_equal [], warnings
  end

  def test_missing_return_if_else_both_return
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def pick(flag: bool) -> i32:
          if flag:
              return 1
          else:
              return 2
    MT

    refute_any(warnings, "missing-return")
  end

  def test_missing_return_if_without_else_warns
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def pick(flag: bool) -> i32:
          if flag:
              return 1
    MT

    assert_any(warnings, "missing-return")
  end

  # ── lint: ignore inline suppression ────────────────────────────────────

  def test_lint_ignore_suppresses_warning_on_same_line
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          let unused = 1 # lint: ignore
          return 0
    MT

    assert_equal [], warnings
  end

  def test_lint_ignore_rule_code_suppresses_specific_rule
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          let unused = 1 # lint: ignore(unused-local)
          return 0
    MT

    assert_equal [], warnings
  end

  def test_lint_ignore_rule_code_does_not_suppress_other_rules
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          var unused = 1 # lint: ignore(prefer-let)
          return 0
    MT

    # prefer-let suppressed, unused-local still emitted
    assert_equal 1, warnings.length
    assert_equal "unused-local", warnings.first.code
  end

  def test_lint_ignore_leading_comment_suppresses_next_line
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          # lint: ignore(unused-local)
          let unused = 1
          return 0
    MT

    assert_equal [], warnings
  end

  # ── --select / --ignore rule filtering (via lint_source kwargs) ─────────

  def test_select_limits_to_given_rules
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", select: Set["unused-local"])
      module demo.lint

      def compute(x: i32) -> i32:
          let unused = 1
          return 0
    MT

    # unused-param would also fire without select; only unused-local expected
    assert_equal 1, warnings.length
    assert_equal "unused-local", warnings.first.code
  end

  def test_ignore_excludes_given_rules
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["unused-param"])
      module demo.lint

      def compute(x: i32) -> i32:
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
      module demo.lint

      def sign(n: i32) -> i32:
          if n > 0:
              return 1
          else:
              return -1
    MT

    assert_any(warnings, "redundant-else")
  end

  def test_redundant_else_no_warn_when_branch_does_not_return
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["missing-return"])
      module demo.lint

      def sign(n: i32) -> i32:
          if n > 0:
              let _x = 1
          else:
              return -1
    MT

    refute_any(warnings, "redundant-else")
  end

  def test_redundant_else_no_warn_without_else
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["missing-return"])
      module demo.lint

      def sign(n: i32) -> i32:
          if n > 0:
              return 1
    MT

    refute_any(warnings, "redundant-else")
  end

  def test_redundant_else_multi_branch_all_return
    # if/elif both return → else is redundant
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def classify(n: i32) -> i32:
          if n > 0:
              return 1
          elif n < 0:
              return -1
          else:
              return 0
    MT

    assert_any(warnings, "redundant-else")
  end

  # ── shadow ─────────────────────────────────────────────────────────────

  def test_shadow_warns_when_inner_redeclares_outer_name
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          let x = 1
          if true:
              let x = 2
              return x
          return x
    MT

    assert_any(warnings, "shadow")
    shadow_w = warnings.find { |w| w.code == "shadow" }
    assert_match(/'x'/, shadow_w.message)
    assert_equal 6, shadow_w.line
  end

  def test_no_shadow_in_same_scope
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          let x = 1
          return x
    MT

    refute_any(warnings, "shadow")
  end

  def test_shadow_ignores_underscore_names
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
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
      module demo.lint

      def compute() -> i32:
          let _x = 1
    MT

    w = warnings.find { |x| x.code == "missing-return" }
    assert w, "expected missing-return warning"
    assert_equal :error, w.severity
  end

  def test_prefer_let_has_hint_severity
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          var x = 1
          return x
    MT

    w = warnings.find { |x| x.code == "prefer-let" }
    assert w, "expected prefer-let warning"
    assert_equal :hint, w.severity
  end

  def test_unused_local_has_warning_severity
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          let unused = 1
          return 0
    MT

    w = warnings.find { |x| x.code == "unused-local" }
    assert w, "expected unused-local warning"
    assert_equal :warning, w.severity
  end

  # ── MethodsBlock linting ──────────────────────────────────────────────

  def test_lints_methods_inside_methods_block
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      struct Counter:
          value: i32

      methods Counter:
          def get() -> i32:
              let unused = 1
              return this.value
    MT

    assert_any(warnings, "unused-local")
    w = warnings.find { |x| x.code == "unused-local" }
    assert_match(/'unused'/, w.message)
  end

  def test_no_warnings_for_clean_method
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      struct Counter:
          value: i32

      methods Counter:
          def get() -> i32:
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

# ── Config file support ────────────────────────────────────────────────────

class MilkTeaLinterConfigTest < Minitest::Test
  include LintHelpers
  def test_config_select_limits_rules
    Dir.mktmpdir("mt-lint-config") do |dir|
      File.write(File.join(dir, ".mt-lint.yml"), "select:\n  - unused-local\n")
      path = File.join(dir, "sample.mt")
      File.write(path, <<~MT)
        module demo.lint

        def compute(x: i32) -> i32:
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
        module demo.lint

        def main() -> i32:
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
        module demo.lint

        def compute(x: i32) -> i32:
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
        module demo.lint

        def compute(x: i32) -> i32:
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
      module demo.fix

      def sign(n: i32) -> i32:
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
      module demo.fix

      def sign(n: i32) -> i32:
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
      module demo.fix

      def classify(n: i32) -> i32:
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
      module demo.lint

      def main() -> i32:
          42
          return 0
    MT

    assert_any warnings, "useless-expression"
  end

  def test_warns_on_binary_op_statement
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          1 + 2
          return 0
    MT

    assert_any warnings, "useless-expression"
  end

  def test_warns_on_string_literal_statement
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          "hello"
          return 0
    MT

    assert_any warnings, "useless-expression"
  end

  def test_no_warn_on_call_statement
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def side_effect() -> i32:
          return 1

      def main() -> i32:
          side_effect()
          return 0
    MT

    refute_any warnings, "useless-expression"
  end

  def test_useless_expression_has_warning_severity
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          42
          return 0
    MT

    w = warnings.find { |x| x.code == "useless-expression" }
    assert w
    assert_equal :warning, w.severity
  end
end

# ── fix_source: unused-import + dead-assignment ────────────────────────────

class MilkTeaLinterFixUnusedImportDeadAssignmentTest < Minitest::Test
  def test_fix_source_removes_unused_import
    source = <<~MT
      module demo.fix

      import demo.other

      def main() -> i32:
          return 0
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    refute_match(/import demo\.other/, fixed)
  end

  def test_fix_source_keeps_used_import
    source = <<~MT
      module demo.fix

      import demo.other

      def main() -> i32:
          let x: other.Value = other.Value.new()
          return 0
    MT

    fixed = MilkTea::Linter.fix_source(source, path: "demo.mt")

    assert_match(/import demo\.other/, fixed)
  end

  def test_fix_source_removes_dead_assignment
    source = <<~MT
      module demo.fix

      def compute(n: i32) -> i32:
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
      module demo.fix

      def compute(n: i32) -> i32:
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
      module demo.lint

      def main() -> i32:
          var x: i32 = 1
          x = x
          return x
    MT

    w = warnings.find { |w| w.code == "self-assignment" }
    assert w, "expected self-assignment warning"
    assert_equal 5, w.line
    assert_match(/'x'/, w.message)
  end

  def test_no_warn_on_normal_assignment
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          var x: i32 = 1
          var y: i32 = 2
          x = y
          return x
    MT

    refute warnings.any? { |w| w.code == "self-assignment" }
  end

  def test_no_warn_on_compound_self_assignment
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          var x: i32 = 1
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
      module demo.lint

      def main(x: i32) -> i32:
          if x == x:
              return 1
          return 0
    MT

    w = warnings.find { |w| w.code == "self-comparison" }
    assert w, "expected self-comparison warning"
    assert_match(/'x'/, w.message)
    assert_match(/always true/, w.message)
  end

  def test_warns_on_self_not_equal_comparison
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main(x: i32) -> i32:
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
      module demo.lint

      def main(x: i32, y: i32) -> i32:
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
      module demo.lint

      def main() -> i32:
          if true:
              return 1
          else:
              return 0
    MT

    w = warnings.find { |w| w.code == "constant-condition" }
    assert w, "expected constant-condition warning"
    assert_match(/always true/, w.message)
    assert_equal 4, w.line
  end

  def test_warns_on_literal_false_in_if
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          if false:
              return 1
          return 0
    MT

    w = warnings.find { |w| w.code == "constant-condition" }
    assert w, "expected constant-condition warning"
    assert_match(/always false/, w.message)
  end

  def test_warns_on_literal_false_in_while
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          while false:
              let _x = 1
          return 0
    MT

    w = warnings.find { |w| w.code == "constant-condition" }
    assert w, "expected constant-condition warning"
    assert_match(/always false/, w.message)
  end

  def test_no_warn_on_while_true
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          while true:
              return 42
    MT

    refute warnings.any? { |w| w.code == "constant-condition" }
  end

  def test_warns_on_cp_constant_variable_in_if
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["unused-local", "prefer-let"])
      module demo.lint

      def main() -> i32:
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
      module demo.lint

      def main(flag: bool) -> i32:
          if flag:
              return 1
          return 0
    MT

    refute warnings.any? { |w| w.code == "constant-condition" }
  end

  def test_no_constant_condition_or_prefer_let_after_inout_call
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["unused-local"])
      module demo.lint

      def main() -> i32:
          var tab_active: i32 = 0
          gui.tab_bar(inout tab_active)
          if tab_active == 0:
              return 1
          elif tab_active == 1:
              return 2
          return 3
    MT

    refute warnings.any? { |w| w.code == "constant-condition" }
    refute warnings.any? { |w| w.code == "prefer-let" && w.symbol_name == "tab_active" }
  end
end

# ── redundant-null-check ───────────────────────────────────────────────────

class MilkTeaLinterRedundantNullCheckTest < Minitest::Test
  def test_warns_on_redundant_null_check_inside_non_null_branch
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["unused-local"])
      module demo.lint

      def process(x: i32?) -> i32:
          if x != null:
              if x != null:
                  let _v = 1
              return 1
          return 0
    MT

    w = warnings.find { |w| w.code == "redundant-null-check" }
    assert w, "expected redundant-null-check warning"
    assert_match(/'x'/, w.message)
    assert_equal :hint, w.severity
  end

  def test_no_warn_on_first_null_check
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["unused-local"])
      module demo.lint

      def process(x: i32?) -> i32:
          if x != null:
              let _v = 1
              return 1
          return 0
    MT

    refute warnings.any? { |w| w.code == "redundant-null-check" }
  end
end

# ── loop-single-iteration ──────────────────────────────────────────────────

class MilkTeaLinterLoopSingleIterationTest < Minitest::Test
  def test_warns_on_while_loop_that_always_breaks
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["constant-condition"])
      module demo.lint

      def main() -> i32:
          var result: i32 = 0
          while true:
              result = 1
              break
          return result
    MT

    w = warnings.find { |w| w.code == "loop-single-iteration" }
    assert w, "expected loop-single-iteration warning"
    assert_equal 5, w.line
  end

  def test_warns_on_while_loop_that_always_returns
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt", ignore: Set["missing-return", "constant-condition"])
      module demo.lint

      def find() -> i32:
          while true:
              return 42
    MT

    w = warnings.find { |w| w.code == "loop-single-iteration" }
    assert w, "expected loop-single-iteration warning"
  end

  def test_no_warn_on_normal_loop
    warnings = MilkTea::Linter.lint_source(<<~MT, path: "demo.mt")
      module demo.lint

      def main() -> i32:
          var i: i32 = 0
          while i < 10:
              i = i + 1
          return i
    MT

    refute warnings.any? { |w| w.code == "loop-single-iteration" }
  end
end
