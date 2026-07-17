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


# =============================================================================
#  doc-tag
# =============================================================================

@[test]
function test_doc_tag_valid_clean() -> t.Check:
    var source = <<-SRC
        ## @param a first
        ## @param b second
        function add(a: int, b: int) -> int:
            return a + b
    SRC
    return expect_none(source, "doc-tag")


@[test]
function test_doc_tag_param_mismatch_flagged() -> t.Check:
    var source = <<-SRC
        ## @param nope not a real param
        function add(a: int, b: int) -> int:
            return a + b
    SRC
    return expect_one(source, "doc-tag")


@[test]
function test_doc_tag_unknown_tag_flagged() -> t.Check:
    var source = <<-SRC
        ## @bogus something
        function demo() -> int:
            return 0
    SRC
    return expect_one(source, "doc-tag")


@[test]
function test_doc_tag_on_struct_flagged() -> t.Check:
    var source = <<-SRC
        ## @param x nope
        struct Point:
            x: int
    SRC
    return expect_one(source, "doc-tag")


# =============================================================================
#  dead-assignment
# =============================================================================

@[test]
function test_dead_assignment_flagged() -> t.Check:
    var source = <<-SRC
        function demo() -> int:
            var x = 1
            x = 2
            return x
    SRC
    return expect_one(source, "dead-assignment")


@[test]
function test_dead_assignment_clean() -> t.Check:
    var source = <<-SRC
        function demo() -> int:
            var x = 1
            return x
    SRC
    return expect_none(source, "dead-assignment")


@[test]
function test_dead_assignment_reused_clean() -> t.Check:
    var source = <<-SRC
        function demo() -> int:
            var x = 5
            var y = x + 1
            return y
    SRC
    return expect_none(source, "dead-assignment")


# =============================================================================
#  unreachable-code
# =============================================================================

@[test]
function test_unreachable_after_return_flagged() -> t.Check:
    # Both `var x = 2` and `return x` are dead after the first return.
    var source = <<-SRC
        function demo() -> int:
            return 1
            var x = 2
            return x
    SRC
    var warns = lint_text(source)
    defer warns.release()
    return t.expect_equal_int(int<-(count_code(ref_of(warns), "unreachable-code")), 2)


@[test]
function test_unreachable_statement_clean() -> t.Check:
    var source = <<-SRC
        function demo(a: int) -> int:
            if a > 0:
                return 1
            else:
                return -1
    SRC
    return expect_none(source, "unreachable-code")


# =============================================================================
#  constant-condition
# =============================================================================

@[test]
function test_constant_condition_true_flagged() -> t.Check:
    var source = <<-SRC
        function demo() -> int:
            if true:
                return 1
            return 0
    SRC
    return expect_one(source, "constant-condition")


@[test]
function test_constant_condition_false_flagged() -> t.Check:
    var source = <<-SRC
        function demo() -> int:
            var x = 0
            while false:
                x += 1
            return x
    SRC
    return expect_one(source, "constant-condition")


@[test]
function test_constant_condition_self_equal_flagged() -> t.Check:
    var source = <<-SRC
        function demo(a: int) -> int:
            if a == a:
                return 1
            return 0
    SRC
    return expect_one(source, "constant-condition")


@[test]
function test_constant_condition_not_self_not_equal_flagged() -> t.Check:
    var source = <<-SRC
        function demo(a: int) -> int:
            if not (a != a):
                return 1
            return 0
    SRC
    return expect_one(source, "constant-condition")


@[test]
function test_constant_condition_normal_clean() -> t.Check:
    var source = <<-SRC
        function demo(a: int, b: int) -> int:
            if a > b:
                return 1
            return 0
    SRC
    return expect_none(source, "constant-condition")


@[test]
function test_constant_condition_different_vars_clean() -> t.Check:
    var source = <<-SRC
        function demo(a: int, b: int) -> int:
            if a == b:
                return 1
            return 0
    SRC
    return expect_none(source, "constant-condition")


# =============================================================================
#  loop-single-iteration
# =============================================================================

@[test]
function test_loop_single_break_flagged() -> t.Check:
    # Loop body always returns on first iteration.
    var source = <<-SRC
        function demo(a: int) -> int:
            while a < 100:
                return a
            return 0
    SRC
    return expect_one(source, "loop-single-iteration")


@[test]
function test_loop_normal_clean() -> t.Check:
    var source = <<-SRC
        function demo() -> int:
            var x = 0
            while x < 10:
                x += 1
            return x
    SRC
    return expect_none(source, "loop-single-iteration")


@[test]
function test_loop_normal_with_break_clean() -> t.Check:
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
    return expect_none(source, "loop-single-iteration")


# =============================================================================
#  prefer-own-ptr
# =============================================================================

@[test]
function test_prefer_own_ptr_flagged() -> t.Check:
    var source = <<-SRC
        import std.mem.heap as heap
        function demo() -> int:
            var p: ptr[int] = heap.must_alloc[int](1)
            unsafe:
                read(p) = 42
                return read(p)
    SRC
    return expect_one(source, "prefer-own-ptr")


@[test]
function test_ptr_used_outside_unsafe_clean() -> t.Check:
    var source = <<-SRC
        import std.mem.heap as heap
        function demo() -> int:
            var p: ptr[int] = heap.must_alloc[int](1)
            var q = p
            heap.release(q)
            return 0
    SRC
    return expect_none(source, "prefer-own-ptr")


# =============================================================================
#  redundant-cast
# =============================================================================

@[test]
function test_redundant_cast_flagged() -> t.Check:
    var source = <<-SRC
        function demo(x: int) -> int:
            var y: int = x
            return int<-y
    SRC
    return expect_one(source, "redundant-cast")


@[test]
function test_valid_cast_clean() -> t.Check:
    var source = <<-SRC
        function demo(x: float) -> int:
            return int<-x
    SRC
    return expect_none(source, "redundant-cast")


# =============================================================================
#  redundant-null-check
# =============================================================================

@[test]
function test_redundant_null_check_nested_flagged() -> t.Check:
    var source = <<-SRC
        function demo(x: ptr[int]?) -> int:
            if x != null:
                if x != null:
                    return 1
                return 2
            return 0
    SRC
    return expect_one(source, "redundant-null-check")


@[test]
function test_first_null_check_clean() -> t.Check:
    var source = <<-SRC
        function demo(x: ptr[int]?) -> int:
            if x != null:
                return 1
            return 0
    SRC
    return expect_none(source, "redundant-null-check")


@[test]
function test_null_check_after_guard_return_flagged() -> t.Check:
    # `if x == null: return` narrows x for the rest of the body.
    var source = <<-SRC
        function demo(x: ptr[int]?) -> int:
            if x == null:
                return 0
            if x != null:
                return 1
            return 2
    SRC
    return expect_one(source, "redundant-null-check")


@[test]
function test_null_check_after_write_clean() -> t.Check:
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
    return expect_none(source, "redundant-null-check")


@[test]
function test_null_check_in_loop_with_write_clean() -> t.Check:
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
    return expect_none(source, "redundant-null-check")


@[test]
function test_null_check_narrowed_by_while_condition_flagged() -> t.Check:
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
    return expect_one(source, "redundant-null-check")


@[test]
function test_null_check_and_composition_flagged() -> t.Check:
    var source = <<-SRC
        function demo(x: ptr[int]?, y: ptr[int]?) -> int:
            if x != null and y != null:
                if y != null:
                    return 1
            return 0
    SRC
    return expect_one(source, "redundant-null-check")


@[test]
function test_null_check_not_composition_flagged() -> t.Check:
    var source = <<-SRC
        function demo(x: ptr[int]?) -> int:
            if not (x == null):
                if x != null:
                    return 1
            return 0
    SRC
    return expect_one(source, "redundant-null-check")


@[test]
function test_equality_null_check_not_reported() -> t.Check:
    # Only `!=` guards are reported, matching the Ruby rule.
    var source = <<-SRC
        function demo(x: ptr[int]?) -> int:
            if x != null:
                if x == null:
                    return 1
            return 0
    SRC
    return expect_none(source, "redundant-null-check")


@[test]
function test_null_check_after_borrow_clean() -> t.Check:
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
    return expect_none(source, "redundant-null-check")
