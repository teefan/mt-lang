## In-language linter tests for the self-hosted mtc compiler.
## Run with: mtc test projects/mtc

import std.testing as t
import std.vec as vec
import std.str

import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.linter.linter as linter


## Parse and lint `source`, returning its warnings.
function lint_text(source: str) -> vec.Vec[linter.Warning]:
    var diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer diags.release()
    let file = parser.parse_source(source, ref_of(diags))
    return linter.lint_source(file, source, "test.mt")


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


function expect_one(source: str, code: str) -> t.Check:
    var warns = lint_text(source)
    defer warns.release()
    return t.expect_equal_int(int<-(count_code(ref_of(warns), code)), 1)


function expect_none(source: str, code: str) -> t.Check:
    var warns = lint_text(source)
    defer warns.release()
    return t.expect_equal_int(int<-(count_code(ref_of(warns), code)), 0)


# =============================================================================
#  self-assignment
# =============================================================================

@[test]
function test_self_assignment_flagged() -> t.Check:
    var source = <<-SRC
        function demo(a: int) -> void:
            var x = a
            x = x
    SRC
    return expect_one(source, "self-assignment")


@[test]
function test_distinct_assignment_clean() -> t.Check:
    var source = <<-SRC
        function demo(a: int) -> void:
            var x = a
            x = a
    SRC
    return expect_none(source, "self-assignment")


# =============================================================================
#  self-comparison
# =============================================================================

@[test]
function test_self_comparison_flagged() -> t.Check:
    var source = <<-SRC
        function demo(a: int) -> int:
            if a == a:
                return 1
            return 0
    SRC
    return expect_one(source, "self-comparison")


@[test]
function test_self_comparison_message_and_line() -> t.Check:
    var source = <<-SRC
        function demo(a: int) -> int:
            if a != a:
                return 1
            return 0
    SRC
    var warns = lint_text(source)
    defer warns.release()
    let wp = warns.get(0) else:
        return t.fail("expected a warning")
    unsafe:
        let w = read(wp)
        if not w.code.equal("self-comparison"):
            return t.fail("wrong code")
        if w.line != 2:
            return t.fail("wrong line")
        return t.expect_true(w.message.contains_substring("always false"))


@[test]
function test_distinct_comparison_clean() -> t.Check:
    var source = <<-SRC
        function demo(a: int, b: int) -> int:
            if a == b:
                return 1
            return 0
    SRC
    return expect_none(source, "self-comparison")


# =============================================================================
#  redundant-bool-compare
# =============================================================================

@[test]
function test_redundant_bool_compare_flagged() -> t.Check:
    var source = <<-SRC
        function demo(a: bool) -> int:
            if a == true:
                return 1
            return 0
    SRC
    return expect_one(source, "redundant-bool-compare")


@[test]
function test_bool_literal_both_sides_clean() -> t.Check:
    # Two boolean literals is not the redundant-compare pattern.
    var source = <<-SRC
        function demo() -> int:
            if true == false:
                return 1
            return 0
    SRC
    return expect_none(source, "redundant-bool-compare")


# =============================================================================
#  redundant-return
# =============================================================================

@[test]
function test_redundant_return_flagged() -> t.Check:
    var source = <<-SRC
        function demo() -> void:
            return
    SRC
    return expect_one(source, "redundant-return")


@[test]
function test_return_with_value_clean() -> t.Check:
    var source = <<-SRC
        function demo() -> int:
            return 0
    SRC
    return expect_none(source, "redundant-return")


@[test]
function test_implicit_void_return_clean() -> t.Check:
    # Only an explicit `-> void` triggers redundant-return.
    var source = <<-SRC
        function demo():
            return
    SRC
    return expect_none(source, "redundant-return")


# =============================================================================
#  useless-expression
# =============================================================================

@[test]
function test_useless_expression_flagged() -> t.Check:
    var source = <<-SRC
        function demo(a: int) -> int:
            a
            return a
    SRC
    return expect_one(source, "useless-expression")


@[test]
function test_call_statement_clean() -> t.Check:
    # A bare call has side effects and is not useless.
    var source = <<-SRC
        function side() -> int:
            return 0
        function demo() -> int:
            side()
            return 0
    SRC
    return expect_none(source, "useless-expression")


# =============================================================================
#  duplicate-if-condition
# =============================================================================

@[test]
function test_duplicate_if_condition_flagged() -> t.Check:
    var source = <<-SRC
        function demo(a: int) -> int:
            if a == 1:
                return 1
            else if a == 1:
                return 2
            return 0
    SRC
    return expect_one(source, "duplicate-if-condition")


@[test]
function test_distinct_if_conditions_clean() -> t.Check:
    var source = <<-SRC
        function demo(a: int) -> int:
            if a == 1:
                return 1
            else if a == 2:
                return 2
            return 0
    SRC
    return expect_none(source, "duplicate-if-condition")


# =============================================================================
#  noop-compound-assignment
# =============================================================================

@[test]
function test_noop_compound_add_zero_flagged() -> t.Check:
    var source = <<-SRC
        function demo() -> int:
            var x = 0
            x += 0
            return x
    SRC
    return expect_one(source, "noop-compound-assignment")


@[test]
function test_noop_compound_mul_one_flagged() -> t.Check:
    var source = <<-SRC
        function demo() -> int:
            var x = 2
            x *= 1
            return x
    SRC
    return expect_one(source, "noop-compound-assignment")


@[test]
function test_compound_nonidentity_clean() -> t.Check:
    var source = <<-SRC
        function demo(y: int) -> int:
            var x = 0
            x += y
            x *= 2
            return x
    SRC
    return expect_none(source, "noop-compound-assignment")


# =============================================================================
#  redundant-ignored-match-binding
# =============================================================================

@[test]
function test_redundant_ignored_match_binding_flagged() -> t.Check:
    var source = <<-SRC
        function demo() -> int:
            let opt = Option[int].some(value = 5)
            match opt:
                Option.some as _:
                    return 1
                Option.none:
                    return 0
    SRC
    return expect_one(source, "redundant-ignored-match-binding")


@[test]
function test_named_match_binding_clean() -> t.Check:
    var source = <<-SRC
        function demo() -> int:
            let opt = Option[int].some(value = 5)
            match opt:
                Option.some as s:
                    return s.value
                Option.none:
                    return 0
    SRC
    return expect_none(source, "redundant-ignored-match-binding")


# =============================================================================
#  redundant-else
# =============================================================================

@[test]
function test_redundant_else_flagged() -> t.Check:
    var source = <<-SRC
        function demo(a: int) -> int:
            if a > 0:
                return 1
            else:
                return 2
    SRC
    return expect_one(source, "redundant-else")


@[test]
function test_else_after_nonreturning_clean() -> t.Check:
    var source = <<-SRC
        function demo(a: int) -> int:
            var x = 0
            if a > 0:
                x = 1
            else:
                x = 2
            return x
    SRC
    return expect_none(source, "redundant-else")


@[test]
function test_redundant_else_with_fatal_flagged() -> t.Check:
    # `fatal(...)` is a terminating expression, so the branch always exits.
    var source = <<-SRC
        function demo(a: int) -> int:
            if a > 0:
                fatal(c"nope")
            else:
                return 2
    SRC
    return expect_one(source, "redundant-else")


# =============================================================================
#  event-capacity
# =============================================================================

@[test]
function test_large_event_capacity_flagged() -> t.Check:
    var source = <<-SRC
        event big[128]
    SRC
    return expect_one(source, "event-capacity")


@[test]
function test_small_event_capacity_clean() -> t.Check:
    var source = <<-SRC
        event small[4]
    SRC
    return expect_none(source, "event-capacity")


# =============================================================================
#  trailing-list-comma
# =============================================================================

@[test]
function test_trailing_list_comma_flagged() -> t.Check:
    var source = <<-SRC
        function side(a: int, b: int) -> int:
            return a + b

        function demo() -> int:
            return side(
                1,
                2,
            )
    SRC
    return expect_one(source, "trailing-list-comma")


@[test]
function test_no_trailing_comma_clean() -> t.Check:
    var source = <<-SRC
        function side(a: int, b: int) -> int:
            return a + b

        function demo() -> int:
            return side(1, 2)
    SRC
    return expect_none(source, "trailing-list-comma")
