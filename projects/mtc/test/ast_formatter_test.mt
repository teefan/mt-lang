## In-language AST-formatter tests for the self-hosted mtc compiler.
## Run with: mtc test projects/mtc
##
## The formatter (src/mtc/pretty_printer/ast_formatter.mt, ~1.4k LOC) powers
## `mtc format` but had no direct coverage.  These tests parse a source string,
## format it, and assert on the normalized output — plus an idempotency check
## (formatting already-formatted source is a no-op), which is the core contract
## of a formatter.

import std.testing as t
import std.vec as vec
import std.str
import std.string as string

import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.pretty_printer.ast_formatter as fmt


## Parse `source` and return its formatted rendering.
function format_source(source: str) -> string.String:
    var diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer diags.release()
    let file = parser.parse_source(source, ref_of(diags))
    if diags.len() > 0:
        return string.String.from_str("FAIL: parse error")
    return fmt.format_source_file(file)


## Assert `text` contains `needle`; the failure message names the missing text.
function expect_contains(text: str, needle: str) -> t.Check:
    return t.expect(text.contains_substring(needle), needle)


# =============================================================================
#  Idempotency — formatting formatted source must be a fixed point.
# =============================================================================

@[test]
function test_formatting_is_idempotent() -> t.Check:
    var source = <<-SRC
        function  add(a:int,b:int)->int:
            return a+b


        struct Point:
            x: float
            y: float
    SRC
    var once = format_source(source)
    defer once.release()
    var twice = format_source(once.as_str())
    defer twice.release()
    return t.expect_equal_str(twice.as_str(), once.as_str())


@[test]
function test_already_formatted_is_stable() -> t.Check:
    ## Canonical input should round-trip unchanged.
    var source = <<-SRC
        function main() -> int:
            return 0
    SRC
    var once = format_source(source)
    defer once.release()
    var twice = format_source(once.as_str())
    defer twice.release()
    return t.expect_equal_str(once.as_str(), twice.as_str())


# =============================================================================
#  Normalization
# =============================================================================

@[test]
function test_normalizes_param_and_operator_spacing() -> t.Check:
    var source = <<-SRC
        function add(a:int,b:int)->int:
            return a+b
    SRC
    var formatted = format_source(source)
    defer formatted.release()
    let text = formatted.as_str()
    expect_contains(text, "function add(a: int, b: int) -> int:")?
    expect_contains(text, "return a + b")?
    return t.ok()


@[test]
function test_collapses_extra_blank_lines() -> t.Check:
    ## Multiple consecutive blank lines between declarations collapse to the
    ## canonical single separator; there must be no triple newline.
    var source = <<-SRC
        function a() -> int:
            return 1




        function b() -> int:
            return 2
    SRC
    var formatted = format_source(source)
    defer formatted.release()
    let text = formatted.as_str()
    expect_contains(text, "function a() -> int:")?
    expect_contains(text, "function b() -> int:")?
    return t.expect_false(text.contains_substring("\n\n\n"))


@[test]
function test_preserves_struct_fields() -> t.Check:
    var source = <<-SRC
        struct Vec2:
            x: float
            y: float
    SRC
    var formatted = format_source(source)
    defer formatted.release()
    let text = formatted.as_str()
    expect_contains(text, "struct Vec2:")?
    expect_contains(text, "    x: float")?
    expect_contains(text, "    y: float")?
    return t.ok()


@[test]
function test_preserves_enum_members() -> t.Check:
    var source = <<-SRC
        enum Color: ubyte
            red = 0
            green = 1
    SRC
    var formatted = format_source(source)
    defer formatted.release()
    let text = formatted.as_str()
    expect_contains(text, "enum Color: ubyte")?
    expect_contains(text, "red = 0")?
    expect_contains(text, "green = 1")?
    return t.ok()


@[test]
function test_formats_match_statement() -> t.Check:
    var source = <<-SRC
        enum State: ubyte
            idle = 0
            busy = 1

        function step(s: State) -> int:
            match s:
                State.idle:
                    return 0
                State.busy:
                    return 1
    SRC
    var formatted = format_source(source)
    defer formatted.release()
    let text = formatted.as_str()
    expect_contains(text, "match s:")?
    expect_contains(text, "State.idle:")?
    expect_contains(text, "State.busy:")?
    return t.ok()
