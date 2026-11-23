## In-language linter tests for the self-hosted mtc compiler.
## Run with: mtc test projects/mtc

import std.vec as vec
import std.str

import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.linter.linter as linter
import mtc.semantic.analyzer as analyzer


## Parse and lint `source`, returning its warnings.
function lint_text(source: str) -> vec.Vec[linter.Warning]:
    var diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: diags.release()
    let file = parser.parse_source(source, ref_of(diags))
    return linter.lint_source(file, source, "test.mt", span[str]())


## Count warnings whose code equals `code`.
function count_code(warns: ref[vec.Vec[linter.Warning]], code: str) -> ptr_uint:
    var n: ptr_uint = 0
    var i: ptr_uint = 0
    while i < warns.len():
        let wp = warns.get(i) else:
            break
        unsafe:
            if read(wp).code.equal(code):
                n += 1
        i += 1
    return n


function expect_one(source: str, code: str) -> void:
    var warns = lint_text(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), code)), 1)


function expect_none(source: str, code: str) -> void:
    var warns = lint_text(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), code)), 0)


## Lint `source` through the options funnel (the entry the CLI/LSP use).
function lint_with_options(source: str, options: linter.LintOptions) -> vec.Vec[linter.Warning]:
    var diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: diags.release()
    let file = parser.parse_source(source, ref_of(diags))
    return linter.lint_source_with(file, source, "test.mt", options)


## The message of the first warning with `code`, or "".
function message_of(warns: ref[vec.Vec[linter.Warning]], code: str) -> str:
    var i: ptr_uint = 0
    while i < warns.len():
        let wp = warns.get(i) else:
            break
        unsafe:
            let w = read(wp)
            if w.code.equal(code):
                return w.message
        i += 1
    return ""


## The first warning with `code`; a zeroed Warning when absent.
function warning_of(warns: ref[vec.Vec[linter.Warning]], code: str) -> linter.Warning:
    var i: ptr_uint = 0
    while i < warns.len():
        let wp = warns.get(i) else:
            break
        unsafe:
            if read(wp).code.equal(code):
                return read(wp)
        i += 1
    return linter.Warning(path = "", line = 0, column = 0, length = 0, code = "", message = "", severity = "")


# =============================================================================
#  line-too-long
# =============================================================================

@[test]
function test_line_too_long_wrappable_line_flagged_with_hint() -> void:
    var source = "function demo(a: int) -> void:\n    consume(first_argument, second_argument, third_argument, fourth_argument, fifth_argument, sixth_argument, seventh_argument)\n"
    var warns = lint_text(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "line-too-long")), 1)
    expect(message_of(ref_of(warns), "line-too-long").contains_substring("; wrap the expression"), "wrap hint")


@[test]
function test_line_too_long_non_wrappable_line_ignored() -> void:
    var source = "function demo(a: int) -> void:\n    let text = \"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"\n"
    expect_none(source, "line-too-long")


@[test]
function test_line_too_long_foreign_header_ignored() -> void:
    var source = "public foreign function really_long_name(alpha: int, beta: int, gamma: int, delta: int, epsilon: int, zeta: int) -> void = c.foo\n"
    expect_none(source, "line-too-long")


# =============================================================================
#  redundant-cast (sema-backed)
# =============================================================================

## Lint `source` with a single-file analysis — the type-backed rules need it.
function lint_text_with_analysis(source: str) -> vec.Vec[linter.Warning]:
    var diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: diags.release()
    let file = parser.parse_source(source, ref_of(diags))
    var analysis = analyzer.check_source_file(file)
    var options = linter.default_lint_options()
    options.analysis = ptr_of(analysis)
    return linter.lint_source_with(file, source, "test.mt", options)


@[test]
function test_redundant_cast_same_type() -> void:
    let source = "function demo(a: int) -> int:\n    let x: int = a\n    return int<-x\n"
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "redundant-cast")), 1)
    expect(message_of(ref_of(warns), "redundant-cast").contains_substring("same type is redundant: int<-"), "same type")


@[test]
function test_redundant_cast_widening_slot() -> void:
    let source = "function demo(a: int) -> long:\n    let b: long = long<-a\n    return b\n"
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "redundant-cast")), 1)
    expect(message_of(ref_of(warns), "redundant-cast").contains_substring("implicit widening makes this cast redundant: long<-"), "widening")


@[test]
function test_redundant_cast_literal_slot() -> void:
    let source = "function demo() -> ubyte:\n    let e: ubyte = ubyte<-200\n    return e\n"
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "redundant-cast")), 1)
    expect(message_of(ref_of(warns), "redundant-cast").contains_substring("integer literal coercion makes this cast redundant: ubyte<-"), "literal")


@[test]
function test_redundant_cast_parens() -> void:
    let source = "function demo(a: int) -> byte:\n    let b: byte = byte<-(a)\n    return b\n"
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "redundant-cast")), 1)
    expect(message_of(ref_of(warns), "redundant-cast").contains_substring("parentheses around cast expression are redundant: byte<-"), "parens")


@[test]
function test_redundant_cast_float_operand() -> void:
    let source = "function demo(a: int, f: float) -> float:\n    return f + float<-a\n"
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "redundant-cast")), 1)
    expect(message_of(ref_of(warns), "redundant-cast").contains_substring("implicit float widening makes this cast redundant: float<-"), "float operand")


@[test]
function test_redundant_cast_narrowing_clean() -> void:
    let source = "function demo(a: long) -> int:\n    return int<-a\n"
    expect_none(source, "redundant-cast")


# =============================================================================
#  select/ignore options and `# lint: ignore` suppressions
# =============================================================================

@[test]
function test_suppression_same_line() -> void:
    var source = <<-SRC
        function demo(a: int) -> int:
            var x = a  # lint: ignore(prefer-let)
            return x
    SRC
    expect_none(source, "prefer-let")


@[test]
function test_suppression_preceding_line() -> void:
    var source = <<-SRC
        function demo(a: int) -> int:
            # lint: ignore(prefer-let)
            var x = a
            return x
    SRC
    expect_none(source, "prefer-let")


@[test]
function test_suppression_all_rules() -> void:
    var source = <<-SRC
        function demo(a: int) -> void:
            var y = a
            y = y  # lint: ignore
    SRC
    expect_none(source, "self-assignment")


@[test]
function test_suppression_other_code_keeps_warning() -> void:
    var source = <<-SRC
        function demo(a: int) -> int:
            var x = a  # lint: ignore(unused-local)
            return x
    SRC
    expect_one(source, "prefer-let")


@[test]
function test_select_restricts_rules() -> void:
    let source = "function demo(a: int) -> int:\n    var x = a\n    var y = a\n    y = y\n    return x\n"
    var select = vec.Vec[str].create()
    defer: select.release()
    select.push("prefer-let")
    var options = linter.default_lint_options()
    options.select = select.as_span()
    var warns = lint_with_options(source, options)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "prefer-let")), 1)
    expect_eq(int<-(count_code(ref_of(warns), "self-assignment")), 0)


@[test]
function test_ignore_drops_rule() -> void:
    let source = "function demo(a: int) -> int:\n    var x = a\n    var y = a\n    y = y\n    return x\n"
    var ignore = vec.Vec[str].create()
    defer: ignore.release()
    ignore.push("prefer-let")
    var options = linter.default_lint_options()
    options.ignore = ignore.as_span()
    var warns = lint_with_options(source, options)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "prefer-let")), 0)
    expect_eq(int<-(count_code(ref_of(warns), "self-assignment")), 1)


# =============================================================================
#  self-assignment
# =============================================================================

@[test]
function test_self_assignment_flagged() -> void:
    var source = <<-SRC
        function demo(a: int) -> void:
            var x = a
            x = x
    SRC
    expect_one(source, "self-assignment")


@[test]
function test_distinct_assignment_clean() -> void:
    var source = <<-SRC
        function demo(a: int) -> void:
            var x = a
            x = a
    SRC
    expect_none(source, "self-assignment")


# =============================================================================
#  self-comparison
# =============================================================================

@[test]
function test_self_comparison_flagged() -> void:
    var source = <<-SRC
        function demo(a: int) -> int:
            if a == a:
                return 1
            return 0
    SRC
    expect_one(source, "self-comparison")


@[test]
function test_self_comparison_message_and_line() -> void:
    var source = <<-SRC
        function demo(a: int) -> int:
            if a != a:
                return 1
            return 0
    SRC
    var warns = lint_text(source)
    defer: warns.release()
    let wp = warns.get(0) else:
        expect(false, "expected a warning")
    unsafe:
        let w = read(wp)
        if not w.code.equal("self-comparison"):
            expect(false, "wrong code")
        if w.line != 2:
            expect(false, "wrong line")
        expect(w.message.contains_substring("always false"))


@[test]
function test_distinct_comparison_clean() -> void:
    var source = <<-SRC
        function demo(a: int, b: int) -> int:
            if a == b:
                return 1
            return 0
    SRC
    expect_none(source, "self-comparison")


# =============================================================================
#  redundant-bool-compare
# =============================================================================

@[test]
function test_redundant_bool_compare_flagged() -> void:
    var source = <<-SRC
        function demo(a: bool) -> int:
            if a == true:
                return 1
            return 0
    SRC
    expect_one(source, "redundant-bool-compare")


@[test]
function test_bool_literal_both_sides_clean() -> void:
    # Two boolean literals is not the redundant-compare pattern.
    var source = <<-SRC
        function demo() -> int:
            if true == false:
                return 1
            return 0
    SRC
    expect_none(source, "redundant-bool-compare")


# =============================================================================
#  redundant-return
# =============================================================================

@[test]
function test_redundant_return_flagged() -> void:
    var source = <<-SRC
        function demo() -> void:
            return
    SRC
    expect_one(source, "redundant-return")


@[test]
function test_return_with_value_clean() -> void:
    var source = <<-SRC
        function demo() -> int:
            return 0
    SRC
    expect_none(source, "redundant-return")


@[test]
function test_implicit_void_return_clean() -> void:
    # Only an explicit `-> void` triggers redundant-return.
    var source = <<-SRC
        function demo():
            return
    SRC
    expect_none(source, "redundant-return")


# =============================================================================
#  useless-expression
# =============================================================================

@[test]
function test_useless_expression_flagged() -> void:
    var source = <<-SRC
        function demo(a: int) -> int:
            a
            return a
    SRC
    expect_one(source, "useless-expression")


@[test]
function test_call_statement_clean() -> void:
    # A bare call has side effects and is not useless.
    var source = <<-SRC
        function side() -> int:
            return 0
        function demo() -> int:
            side()
            return 0
    SRC
    expect_none(source, "useless-expression")


# =============================================================================
#  duplicate-if-condition
# =============================================================================

@[test]
function test_duplicate_if_condition_flagged() -> void:
    var source = <<-SRC
        function demo(a: int) -> int:
            if a == 1:
                return 1
            else if a == 1:
                return 2
            return 0
    SRC
    expect_one(source, "duplicate-if-condition")


@[test]
function test_duplicate_if_condition_reports_condition_span() -> void:
    var source = <<-SRC
        function demo(a: int) -> int:
            if a == 1:
                return 1
            else if a == 1:
                return 2
            return 0
    SRC
    var warns = lint_text(source)
    defer: warns.release()
    let w = warning_of(ref_of(warns), "duplicate-if-condition")
    expect_eq(int<-w.line, 4)
    expect_eq(int<-w.column, 13)


@[test]
function test_distinct_if_conditions_clean() -> void:
    var source = <<-SRC
        function demo(a: int) -> int:
            if a == 1:
                return 1
            else if a == 2:
                return 2
            return 0
    SRC
    expect_none(source, "duplicate-if-condition")


# =============================================================================
#  noop-compound-assignment
# =============================================================================

@[test]
function test_noop_compound_add_zero_flagged() -> void:
    var source = <<-SRC
        function demo() -> int:
            var x = 0
            x += 0
            return x
    SRC
    expect_one(source, "noop-compound-assignment")


@[test]
function test_noop_compound_mul_one_flagged() -> void:
    var source = <<-SRC
        function demo() -> int:
            var x = 2
            x *= 1
            return x
    SRC
    expect_one(source, "noop-compound-assignment")


@[test]
function test_compound_nonidentity_clean() -> void:
    var source = <<-SRC
        function demo(y: int) -> int:
            var x = 0
            x += y
            x *= 2
            return x
    SRC
    expect_none(source, "noop-compound-assignment")


# =============================================================================
#  redundant-ignored-match-binding
# =============================================================================

@[test]
function test_redundant_ignored_match_binding_flagged() -> void:
    var source = <<-SRC
        function demo() -> int:
            let opt = Option[int].some(value = 5)
            match opt:
                Option.some as _:
                    return 1
                Option.none:
                    return 0
    SRC
    expect_one(source, "redundant-ignored-match-binding")


@[test]
function test_named_match_binding_clean() -> void:
    var source = <<-SRC
        function demo() -> int:
            let opt = Option[int].some(value = 5)
            match opt:
                Option.some as s:
                    return s.value
                Option.none:
                    return 0
    SRC
    expect_none(source, "redundant-ignored-match-binding")


# =============================================================================
#  redundant-else
# =============================================================================

@[test]
function test_redundant_else_flagged() -> void:
    var source = <<-SRC
        function demo(a: int) -> int:
            if a > 0:
                return 1
            else:
                return 2
    SRC
    expect_one(source, "redundant-else")


@[test]
function test_redundant_else_reports_else_keyword_span() -> void:
    var source = <<-SRC
        function demo(a: int) -> int:
            if a > 0:
                return 1
            else:
                return 2
    SRC
    var warns = lint_text(source)
    defer: warns.release()
    let w = warning_of(ref_of(warns), "redundant-else")
    expect_eq(int<-w.line, 4)
    expect_eq(int<-w.column, 5)
    expect_eq(int<-w.length, 4)


@[test]
function test_else_after_nonreturning_clean() -> void:
    var source = <<-SRC
        function demo(a: int) -> int:
            var x = 0
            if a > 0:
                x = 1
            else:
                x = 2
            return x
    SRC
    expect_none(source, "redundant-else")


@[test]
function test_redundant_else_with_fatal_flagged() -> void:
    # `fatal(...)` is a terminating expression, so the branch always exits.
    var source = <<-SRC
        function demo(a: int) -> int:
            if a > 0:
                fatal(c"nope")
            else:
                return 2
    SRC
    expect_one(source, "redundant-else")


# =============================================================================
#  event-capacity
# =============================================================================

@[test]
function test_large_event_capacity_flagged() -> void:
    var source = <<-SRC
        event big[128]
    SRC
    expect_one(source, "event-capacity")


@[test]
function test_small_event_capacity_clean() -> void:
    var source = <<-SRC
        event small[4]
    SRC
    expect_none(source, "event-capacity")


# =============================================================================
#  trailing-list-comma
# =============================================================================

@[test]
function test_trailing_list_comma_flagged() -> void:
    var source = <<-SRC
        function side(a: int, b: int) -> int:
            return a + b

        function demo() -> int:
            return side(
                1,
                2,
            )
    SRC
    expect_one(source, "trailing-list-comma")


@[test]
function test_no_trailing_comma_clean() -> void:
    var source = <<-SRC
        function side(a: int, b: int) -> int:
            return a + b

        function demo() -> int:
            return side(1, 2)
    SRC
    expect_none(source, "trailing-list-comma")


# =============================================================================
#  doc-tag
# =============================================================================

@[test]
function test_doc_tag_valid_clean() -> void:
    var source = <<-SRC
        ## @param a first
        ## @param b second
        function add(a: int, b: int) -> int:
            return a + b
    SRC
    expect_none(source, "doc-tag")


@[test]
function test_doc_tag_param_mismatch_flagged() -> void:
    var source = <<-SRC
        ## @param nope not a real param
        function add(a: int, b: int) -> int:
            return a + b
    SRC
    expect_one(source, "doc-tag")


@[test]
function test_doc_tag_unknown_tag_flagged() -> void:
    var source = <<-SRC
        ## @bogus something
        function demo() -> int:
            return 0
    SRC
    expect_one(source, "doc-tag")


@[test]
function test_doc_tag_on_struct_flagged() -> void:
    var source = <<-SRC
        ## @param x nope
        struct Point:
            x: int
    SRC
    expect_one(source, "doc-tag")


# =============================================================================
#  dead-assignment
# =============================================================================

@[test]
function test_dead_assignment_flagged() -> void:
    var source = <<-SRC
        function demo() -> int:
            var x: int
            x = 1
            x = 2
            return x
    SRC
    expect_one(source, "dead-assignment")
    var warns = lint_text(source)
    defer: warns.release()
    expect(message_of(ref_of(warns), "dead-assignment").contains_substring("value assigned to 'x' is never read"), "host message")


@[test]
function test_dead_assignment_skips_never_read_binding() -> void:
    # A binding that is never read is `unused-local`'s business (host guard).
    var source = <<-SRC
        function demo() -> int:
            var x = 1
            x = 2
            return 0
    SRC
    expect_none(source, "dead-assignment")
    expect_one(source, "unused-local")


@[test]
function test_dead_assignment_clean() -> void:
    var source = <<-SRC
        function demo() -> int:
            var x = 1
            return x
    SRC
    expect_none(source, "dead-assignment")


@[test]
function test_dead_assignment_reused_clean() -> void:
    var source = <<-SRC
        function demo() -> int:
            var x = 5
            var y = x + 1
            return y
    SRC
    expect_none(source, "dead-assignment")


# =============================================================================
#  missing-return
# =============================================================================

@[test]
function test_missing_return_flagged() -> void:
    var source = <<-SRC
        function compute() -> int:
            let x = 1
    SRC
    expect_one(source, "missing-return")
    var warns = lint_text(source)
    defer: warns.release()
    expect(message_of(ref_of(warns), "missing-return").contains_substring("'compute' does not always return a value"), "host message")


@[test]
function test_missing_return_if_without_else_flagged() -> void:
    var source = <<-SRC
        function pick(flag: bool) -> int:
            if flag:
                return 1
    SRC
    expect_one(source, "missing-return")


@[test]
function test_missing_return_method_flagged() -> void:
    var source = <<-SRC
        struct C:
            v: int
        extending C:
            function read() -> int:
                let x = this.v
    SRC
    expect_one(source, "missing-return")


@[test]
function test_missing_return_clean_when_always_returns() -> void:
    var source = <<-SRC
        function pick(flag: bool) -> int:
            if flag:
                return 1
            else:
                return 2
    SRC
    expect_none(source, "missing-return")


@[test]
function test_missing_return_clean_for_void_function() -> void:
    var source = <<-SRC
        function setup():
            let x = 1
    SRC
    expect_none(source, "missing-return")


@[test]
function test_missing_return_clean_when_other_path_fatals() -> void:
    var source = <<-SRC
        function pick(flag: bool) -> int:
            if flag:
                fatal(c"boom")
            else:
                return 1
    SRC
    expect_none(source, "missing-return")


@[test]
function test_missing_return_clean_for_while_true() -> void:
    var source = <<-SRC
        function spin() -> int:
            while true:
                pass
    SRC
    expect_none(source, "missing-return")


@[test]
function test_missing_return_clean_for_static_assert_false() -> void:
    var source = <<-SRC
        function pick(n: int) -> int:
            if n == 8:
                return 1
            static_assert(false, "unsupported")
    SRC
    expect_none(source, "missing-return")


# =============================================================================
#  unreachable-code
# =============================================================================

@[test]
function test_unreachable_after_return_flagged() -> void:
    # Both `var x = 2` and `return x` are dead after the first return.
    var source = <<-SRC
        function demo() -> int:
            return 1
            var x = 2
            return x
    SRC
    var warns = lint_text(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "unreachable-code")), 2)


@[test]
function test_unreachable_expression_statement_reports_source_span() -> void:
    # The CFG node carries no column for an expression statement; the warning
    # recovers the first non-space column from the AST/source.
    var source = <<-SRC
        function helper() -> void:
            pass

        function demo() -> int:
            return 1
            helper()
    SRC
    var warns = lint_text(source)
    defer: warns.release()
    let w = warning_of(ref_of(warns), "unreachable-code")
    expect_eq(int<-w.line, 6)
    expect_eq(int<-w.column, 5)
    expect_eq(int<-w.length, 6)


@[test]
function test_unreachable_statement_clean() -> void:
    var source = <<-SRC
        function demo(a: int) -> int:
            if a > 0:
                return 1
            else:
                return -1
    SRC
    expect_none(source, "unreachable-code")


# =============================================================================
#  constant-condition
# =============================================================================

@[test]
function test_constant_condition_true_flagged() -> void:
    var source = <<-SRC
        function demo() -> int:
            if true:
                return 1
            return 0
    SRC
    expect_one(source, "constant-condition")


@[test]
function test_constant_condition_false_flagged() -> void:
    var source = <<-SRC
        function demo() -> int:
            var x = 0
            while false:
                x += 1
            return x
    SRC
    expect_one(source, "constant-condition")


@[test]
function test_constant_condition_self_equal_clean() -> void:
    # The host folds `a == a` only when `a` has a known constant value; a
    # parameter is `nac`, so the condition is not reported.
    var source = <<-SRC
        function demo(a: int) -> int:
            if a == a:
                return 1
            return 0
    SRC
    expect_none(source, "constant-condition")


@[test]
function test_constant_condition_not_self_not_equal_clean() -> void:
    var source = <<-SRC
        function demo(a: int) -> int:
            if not (a != a):
                return 1
            return 0
    SRC
    expect_none(source, "constant-condition")


@[test]
function test_constant_condition_normal_clean() -> void:
    var source = <<-SRC
        function demo(a: int, b: int) -> int:
            if a > b:
                return 1
            return 0
    SRC
    expect_none(source, "constant-condition")


@[test]
function test_constant_condition_different_vars_clean() -> void:
    var source = <<-SRC
        function demo(a: int, b: int) -> int:
            if a == b:
                return 1
            return 0
    SRC
    expect_none(source, "constant-condition")


# =============================================================================
#  loop-single-iteration
# =============================================================================

@[test]
function test_loop_single_break_flagged() -> void:
    # Loop body always returns on first iteration.
    var source = <<-SRC
        function demo(a: int) -> int:
            while a < 100:
                return a
            return 0
    SRC
    expect_one(source, "loop-single-iteration")


@[test]
function test_loop_single_iteration_reports_loop_keyword_span() -> void:
    var source = <<-SRC
        function demo(a: int) -> int:
            while a < 100:
                return a
            return 0
    SRC
    var warns = lint_text(source)
    defer: warns.release()
    let w = warning_of(ref_of(warns), "loop-single-iteration")
    expect_eq(int<-w.line, 2)
    expect_eq(int<-w.column, 5)
    expect_eq(int<-w.length, 5)


@[test]
function test_loop_single_iteration_reports_for_keyword_span() -> void:
    var source = <<-SRC
        function demo(a: int) -> int:
            for i in 0..10:
                return a
            return 0
    SRC
    var warns = lint_text(source)
    defer: warns.release()
    let w = warning_of(ref_of(warns), "loop-single-iteration")
    expect_eq(int<-w.line, 2)
    expect_eq(int<-w.column, 9)
    expect_eq(int<-w.length, 3)


@[test]
function test_loop_normal_clean() -> void:
    var source = <<-SRC
        function demo() -> int:
            var x = 0
            while x < 10:
                x += 1
            return x
    SRC
    expect_none(source, "loop-single-iteration")


@[test]
function test_loop_normal_with_break_clean() -> void:
    # A loop that CAN break but doesn't always exit is not single-iteration.
    var source = <<-SRC
        function demo() -> int:
            var x = 0
            while x < 10:
                x += 1
                if x > 5:
                    break
            return x
    SRC
    expect_none(source, "loop-single-iteration")


# =============================================================================
#  prefer-own-ptr
# =============================================================================

@[test]
function test_prefer_own_ptr_flagged() -> void:
    # The host's `record_ptr_candidate` never records an annotated declaration
    # (its `type_ref_source(...).include?("ptr[")` test compares against the
    # bare `ptr` name part) and `heap.must_alloc[T](...)` parses through a
    # `Specialization` callee, which `heap_alloc_call?` does not match either.
    # So this shape stays clean, exactly like the host.
    var source = <<-SRC
        import std.mem.heap as heap
        function demo() -> int:
            var p: ptr[int] = heap.must_alloc[int](1)
            unsafe:
                read(p) = 42
                return read(p)
    SRC
    expect_none(source, "prefer-own-ptr")


@[test]
function test_ptr_used_outside_unsafe_clean() -> void:
    var source = <<-SRC
        import std.mem.heap as heap
        function demo() -> int:
            var p: ptr[int] = heap.must_alloc[int](1)
            var q = p
            heap.release(q)
            return 0
    SRC
    expect_none(source, "prefer-own-ptr")


# =============================================================================
#  redundant-cast
# =============================================================================

@[test]
function test_redundant_cast_flagged() -> void:
    var source = <<-SRC
        function demo(x: int) -> int:
            var y: int = x
            return int<-y
    SRC
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "redundant-cast")), 1)


@[test]
function test_valid_cast_clean() -> void:
    var source = <<-SRC
        function demo(x: float) -> int:
            return int<-x
    SRC
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "redundant-cast")), 0)


# =============================================================================
#  redundant-null-check
# =============================================================================

@[test]
function test_redundant_null_check_nested_flagged() -> void:
    var source = <<-SRC
        function demo(x: ptr[int]?) -> int:
            if x != null:
                if x != null:
                    return 1
                return 2
            return 0
    SRC
    expect_one(source, "redundant-null-check")


@[test]
function test_redundant_null_check_reports_condition_span() -> void:
    var source = <<-SRC
        function demo(x: ptr[int]?) -> int:
            if x != null:
                if x != null:
                    return 1
                return 2
            return 0
    SRC
    var warns = lint_text(source)
    defer: warns.release()
    let w = warning_of(ref_of(warns), "redundant-null-check")
    expect_eq(int<-w.line, 3)
    expect_eq(int<-w.column, 12)
    expect_eq(int<-w.length, 9)


@[test]
function test_first_null_check_clean() -> void:
    var source = <<-SRC
        function demo(x: ptr[int]?) -> int:
            if x != null:
                return 1
            return 0
    SRC
    expect_none(source, "redundant-null-check")


@[test]
function test_null_check_after_guard_return_flagged() -> void:
    # `if x == null: return` narrows x for the rest of the body.
    var source = <<-SRC
        function demo(x: ptr[int]?) -> int:
            if x == null:
                return 0
            if x != null:
                return 1
            return 2
    SRC
    expect_one(source, "redundant-null-check")


@[test]
function test_null_check_after_write_clean() -> void:
    # Reassignment kills the narrowing.
    var source = <<-SRC
        function source_ptr() -> ptr[int]?:
            return null

        function demo() -> int:
            var x = source_ptr()
            if x != null:
                x = source_ptr()
                if x != null:
                    return 1
            return 0
    SRC
    expect_none(source, "redundant-null-check")


@[test]
function test_null_check_in_loop_with_write_clean() -> void:
    # Narrowing before a loop does not survive into a body that writes x.
    var source = <<-SRC
        function source_ptr() -> ptr[int]?:
            return null

        function demo() -> int:
            var x = source_ptr()
            var total = 0
            if x == null:
                return 0
            while total < 3:
                if x != null:
                    total += 1
                x = source_ptr()
            return total
    SRC
    expect_none(source, "redundant-null-check")


@[test]
function test_null_check_narrowed_by_while_condition_flagged() -> void:
    # The while condition re-narrows x at the top of every iteration.
    var source = <<-SRC
        function source_ptr() -> ptr[int]?:
            return null

        function demo() -> int:
            var x = source_ptr()
            var n = 0
            while x != null:
                if x != null:
                    n += 1
                x = source_ptr()
            return n
    SRC
    expect_one(source, "redundant-null-check")


@[test]
function test_null_check_and_composition_flagged() -> void:
    var source = <<-SRC
        function demo(x: ptr[int]?, y: ptr[int]?) -> int:
            if x != null and y != null:
                if y != null:
                    return 1
            return 0
    SRC
    expect_one(source, "redundant-null-check")


@[test]
function test_null_check_not_composition_flagged() -> void:
    var source = <<-SRC
        function demo(x: ptr[int]?) -> int:
            if not (x == null):
                if x != null:
                    return 1
            return 0
    SRC
    expect_one(source, "redundant-null-check")


@[test]
function test_equality_null_check_not_reported() -> void:
    # Only `!=` guards are reported, matching the Ruby rule.
    var source = <<-SRC
        function demo(x: ptr[int]?) -> int:
            if x != null:
                if x == null:
                    return 1
            return 0
    SRC
    expect_none(source, "redundant-null-check")


@[test]
function test_null_check_after_borrow_clean() -> void:
    # ref_of hands out a mutable alias; the narrowing is killed.
    var source = <<-SRC
        function reset(slot: ref[ptr[int]?]) -> void:
            read(slot) = null

        function source_ptr() -> ptr[int]?:
            return null

        function demo() -> int:
            var x = source_ptr()
            if x != null:
                reset(ref_of(x))
                if x != null:
                    return 1
            return 0
    SRC
    expect_none(source, "redundant-null-check")


# =============================================================================
#  redundant-unsafe (sema-marked)
# =============================================================================

@[test]
function test_redundant_unsafe_pointer_cast_is_required() -> void:
    # `ptr[T] <- ptr[U]` is a pointer cast, so the enclosing `unsafe:` is
    # required even though both sides are raw pointers.
    let source = "function demo(p: ptr[ubyte]) -> ptr[char]:\n    return unsafe: ptr[char]<-p\n"
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "redundant-unsafe")), 0)


@[test]
function test_redundant_unsafe_cstr_cast_is_required() -> void:
    # `cstr` is pointer-represented: a cast to or from it requires unsafe.
    let source = "function demo(text: ptr[char]) -> cstr:\n    return unsafe: cstr<-text\n"
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "redundant-unsafe")), 0)


@[test]
function test_redundant_unsafe_str_construction_is_required() -> void:
    # A `str(data = ..., len = ...)` construction borrows raw storage (the
    # host's StringView rule), so the block is required even with no cast.
    let source = "function demo(text: ptr[char]) -> str:\n    return unsafe: str(data = text, len = 4)\n"
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "redundant-unsafe")), 0)


@[test]
function test_redundant_unsafe_str_field_read_is_required() -> void:
    # `str.data` is `ptr[char]`, so the pointer arithmetic and `read` need
    # unsafe.
    let source = "function demo(text: str) -> ubyte:\n    return unsafe: ubyte<-read(text.data + 1)\n"
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "redundant-unsafe")), 0)


@[test]
function test_redundant_unsafe_let_else_body_is_marked() -> void:
    # The guard's else block is analyzed, so the cast inside it marks the
    # block instead of the rule reporting it redundant.
    var source = <<-SRC
        function consume(p: ptr[void]) -> void:
            pass

        function maybe() -> Option[int]:
            return Option[int].none

        function demo(req: ptr[int]) -> int:
            let v = maybe() else:
                unsafe: consume(ptr[void]<-req)
                return 0
            return v
    SRC
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "redundant-unsafe")), 0)


@[test]
function test_redundant_unsafe_proc_body_is_marked() -> void:
    # A proc literal's body is checked like the host's proc expressions.
    let source = "function demo(p: ptr[int]) -> int:\n    let f = proc(x: ptr[int]) -> int: unsafe: read(x)\n    return f(p)\n"
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "redundant-unsafe")), 0)


@[test]
function test_redundant_unsafe_format_part_is_marked() -> void:
    # A format string's interpolation parts are inferred.
    let source = "function demo(p: ptr[int]) -> str:\n    return unsafe: f\"value #{read(p)}\"\n"
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "redundant-unsafe")), 0)


# =============================================================================
#  analyzer marks feeding redundant-unsafe (session 21)
# =============================================================================

@[test]
function test_redundant_unsafe_short_circuit_and_marks() -> void:
    # `p != null and read(p)` refines `p` for the right operand, so the read
    # marks the inline `unsafe:`.
    let source = "function demo(p: ptr[int]?) -> bool:\n    return p != null and unsafe: read(p) == 0\n"
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "redundant-unsafe")), 0)


@[test]
function test_redundant_unsafe_if_expression_marks() -> void:
    # The then-branch of an if-expression sees the condition's refinements.
    let source = "function demo(p: ptr[int]?) -> int:\n    return if p != null: unsafe: read(p) else: 0\n"
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "redundant-unsafe")), 0)


@[test]
function test_redundant_unsafe_while_body_marks() -> void:
    # The while body runs only while the condition holds, so `p` is narrowed.
    var source = <<-SRC
        function demo(start: ptr[int]?) -> int:
            var total = 0
            var p = start
            while p != null:
                total += unsafe: read(p)
                p = null
            return total
    SRC
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "redundant-unsafe")), 0)


@[test]
function test_generic_body_cast_is_not_reported() -> void:
    # The host's analyzer does not check generic bodies, so its linter has no
    # expression types there; the self's redundant-cast must fall back to the
    # literal-only paths in that context instead of over-reporting.
    let source = "function demo[T](count: ptr_uint) -> ptr_uint:\n    return ptr_uint<-size_of(T)\n"
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "redundant-cast")), 0)


# =============================================================================
#  prefer-inline-if — the `inline_if_too_wide?` join simulation
# =============================================================================

@[test]
function test_prefer_inline_if_joinable_reported() -> void:
    var source = <<-SRC
        function do_a() -> void:
            pass

        function do_b() -> void:
            pass

        function demo(c: bool) -> void:
            if c:
                do_a()
            else:
                do_b()
    SRC
    var warns = lint_text(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "prefer-inline-if")), 1)


@[test]
function test_prefer_inline_if_too_wide_suppressed() -> void:
    # The composed one-line join exceeds the 120-character budget, so the host
    # reports the chain as unjoinable and emits no hint.
    var source = <<-SRC
        function do_a() -> void:
            pass

        function do_b() -> void:
            pass

        function demo(c: bool) -> void:
            if c:
                do_a_with_a_very_long_name_that_makes_the_joined_line_exceed_the_budget()
            else:
                do_b_with_another_extremely_long_name_for_width_padding_purposes_only()
    SRC
    var warns = lint_text(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "prefer-inline-if")), 0)


@[test]
function test_prefer_inline_if_multiline_body_suppressed() -> void:
    # A branch body spanning more than one physical line cannot be joined.
    var source = <<-SRC
        function consume(a: int, b: int) -> void:
            pass

        function demo(c: bool) -> void:
            if c:
                consume(
                    1,
                    2,
                )
            else:
                consume(3, 4)
    SRC
    var warns = lint_text(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "prefer-inline-if")), 0)


# =============================================================================
#  owning-release-leak / owning-release-double — the CFG precision analysis
# =============================================================================

## Lint `source` with the single-file analysis and an explicit owning-type set
## (the loader normally derives it from the analyses' `.release` methods).
function lint_text_with_owning(source: str, owning: vec.Vec[str]) -> vec.Vec[linter.Warning]:
    var diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: diags.release()
    let file = parser.parse_source(source, ref_of(diags))
    var analysis = analyzer.check_source_file(file)
    var options = linter.default_lint_options()
    options.analysis = ptr_of(analysis)
    options.owning_type_names = owning.as_span()
    return linter.lint_source_with(file, source, "test.mt", options)


function owning_names_one(name: str) -> vec.Vec[str]:
    var names = vec.Vec[str].create()
    names.push(name)
    return names


@[test]
function test_owning_release_leak_conditional_release_is_a_leak() -> void:
    # The CFG path: a release in one branch only leaves the other path to an
    # exit without a consumer (the simple AST path accepted a release
    # anywhere).
    var source = <<-SRC
        public struct Box:
            value: int

        extending Box:
            public function release() -> void:
                pass

        function make_box() -> Box:
            return Box(value = 1)

        function demo(flag: bool) -> void:
            var b: Box = make_box()
            if flag:
                b.release()
    SRC
    var owning = owning_names_one("Box")
    defer: owning.release()
    var warns = lint_text_with_owning(source, owning)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "owning-release-leak")), 1)
    expect(message_of(ref_of(warns), "owning-release-leak").contains_substring("owning binding 'b' of type 'Box' is never released"), "leak message")


@[test]
function test_owning_release_uninitialized_decl_has_no_decl_node() -> void:
    # The host's statement-flow builder writes a declaration only when the
    # local has an initializer, so `var b: Box` (assigned later) never reaches
    # the release analysis.
    var source = <<-SRC
        public struct Box:
            value: int

        extending Box:
            public function release() -> void:
                pass

        function make_box() -> Box:
            return Box(value = 1)

        function demo() -> void:
            var b: Box
            b = make_box()
            b.release()
    SRC
    var owning = owning_names_one("Box")
    defer: owning.release()
    var warns = lint_text_with_owning(source, owning)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "owning-release-leak")), 0)


@[test]
function test_owning_release_own_transfer_inside_unsafe_not_a_leak() -> void:
    # `own_transferred?` walks nested bodies (the host's `_any_stmt?`), so a
    # call handing the binding over inside `unsafe:` is a transfer.
    var source = <<-SRC
        function consume(x: own[int]) -> void:
            x.release()

        function demo() -> void:
            let p = heap.must_alloc[int](1)
            unsafe:
                consume(p)
    SRC
    var owning = vec.Vec[str].create()
    defer: owning.release()
    var warns = lint_text_with_owning(source, owning)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "owning-release-leak")), 0)


@[test]
function test_owning_release_double_across_loop_back_edge() -> void:
    # The path-sensitive double: from the tail release the loop back edge
    # reaches the branch release, which the sequential check cannot see.
    var source = <<-SRC
        public struct Box:
            value: int

        extending Box:
            public function release() -> void:
                pass

        function make_box() -> Box:
            return Box(value = 1)

        function demo(flag: bool) -> void:
            var again = true
            while again:
                var b: Box = make_box()
                if flag:
                    b.release()
                    return
                b.release()
                again = false
    SRC
    var owning = owning_names_one("Box")
    defer: owning.release()
    var warns = lint_text_with_owning(source, owning)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "owning-release-double")), 1)
    expect_eq(int<-(count_code(ref_of(warns), "owning-release-leak")), 0)


# =============================================================================
#  prefer-struct-with — the struct/type gates
# =============================================================================

@[test]
function test_prefer_struct_with_copied_fields_reported() -> void:
    var source = <<-SRC
        public struct Point:
            x: float
            y: float
            z: float

        function demo() -> Point:
            var s = Point(x = 1.0, y = 2.0, z = 3.0)
            return Point(x = s.x, y = s.y, z = 4.0)
    SRC
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "prefer-struct-with")), 1)
    expect(message_of(ref_of(warns), "prefer-struct-with").contains_substring("copies 2 field(s) from `s`; use `s.with(z = …)`"), "with hint")


@[test]
function test_prefer_struct_with_type_mismatch_suppressed() -> void:
    # The copied source's type must be the target struct itself.
    var source = <<-SRC
        public struct Point:
            x: float
            y: float
            z: float

        public struct Vec3:
            x: float
            y: float
            z: float

        function demo(v: Vec3) -> Point:
            return Point(x = v.x, y = v.y, z = 1.0)
    SRC
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "prefer-struct-with")), 0)


@[test]
function test_prefer_struct_with_unnamed_argument_suppressed() -> void:
    var source = <<-SRC
        public struct Point:
            x: float
            y: float
            z: float

        function demo(s: Point) -> Point:
            return Point(x = s.x, s.y, z = 1.0)
    SRC
    var warns = lint_text_with_analysis(source)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "prefer-struct-with")), 0)


# =============================================================================
#  Lint tier (the host's `full_tier?` gates)
# =============================================================================

const TIER_DEAD_SOURCE: str = <<-SRC
function demo() -> int:
    var x: int
    x = 1
    x = 2
    return x
SRC

const TIER_LONG_LINE_SOURCE: str = "function demo(a: int) -> void:\n    consume(first_argument, second_argument, third_argument, fourth_argument, fifth_argument, sixth_argument, seventh_argument)\n"


@[test]
function test_fast_tier_skips_the_flow_rules() -> void:
    var options = linter.default_lint_options()
    options.lint_tier = linter.LintTier.fast
    var warns = lint_with_options(TIER_DEAD_SOURCE, options)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "dead-assignment")), 0)


@[test]
function test_full_tier_runs_the_flow_rules() -> void:
    var options = linter.default_lint_options()
    var warns = lint_with_options(TIER_DEAD_SOURCE, options)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "dead-assignment")), 1)


@[test]
function test_fast_tier_keeps_the_always_on_rules() -> void:
    # `line-too-long` is not gated: the fast tier still reports it.
    var options = linter.default_lint_options()
    options.lint_tier = linter.LintTier.fast
    var warns = lint_with_options(TIER_LONG_LINE_SOURCE, options)
    defer: warns.release()
    expect_eq(int<-(count_code(ref_of(warns), "line-too-long")), 1)
