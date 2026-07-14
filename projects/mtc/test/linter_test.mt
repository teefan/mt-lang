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
    return linter.lint_source(file, "test.mt")


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
