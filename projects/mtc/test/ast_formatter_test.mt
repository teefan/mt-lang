## In-language AST-formatter tests for the self-hosted mtc compiler.
## Run with: mtc test projects/mtc
##
## The formatter (src/mtc/pretty_printer/ast_formatter.mt, ~1.4k LOC) powers
## `mtc format` but had no direct coverage.  These tests parse a source string,
## format it, and assert on the normalized output — plus an idempotency check
## (formatting already-formatted source is a no-op), which is the core contract
## of a formatter.

import std.vec as vec
import std.str
import std.string as string

import mtc.lexer.lexer as lexer
import mtc.lexer.token as tok
import mtc.parser.parser as parser
import mtc.parser.state as pstate
import mtc.pretty_printer.ast_formatter as fmt


## Parse `source` and return its formatted rendering.
function format_source(source: str) -> string.String:
    var diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: diags.release()
    let file = parser.parse_source(source, ref_of(diags))
    if diags.len() > 0:
        return string.String.from_str("FAIL: parse error")
    return fmt.format_source_file(file)


## Parse `source` and format it with comment reattachment — the canonical
## path `mtc format` uses (host `PrettyPrinter.format_ast(ast, trivia:)`).
function format_source_with_comments(source: str) -> string.String:
    var diags = vec.Vec[pstate.ParseDiagnostic].create()
    defer: diags.release()
    let file = parser.parse_source(source, ref_of(diags))
    if diags.len() > 0:
        return string.String.from_str("FAIL: parse error")
    var lex_diags = vec.Vec[tok.LexDiagnostic].create()
    defer: lex_diags.release()
    var lexed = lexer.lex_with_trivia(source, ref_of(lex_diags))
    var result = fmt.format_source_file_with_trivia(file, source, lexed.trivia.as_span())
    lexed.tokens.release()
    lexed.trivia.release()
    return result


## Assert `text` contains `needle`; the failure message names the missing text.
function expect_contains(text: str, needle: str) -> void:
    expect(text.contains_substring(needle), needle)

# =============================================================================
#  Idempotency — formatting formatted source must be a fixed point.
# =============================================================================


@[test]
function test_formatting_is_idempotent() -> void:
    var source = <<-SRC
        function  add(a:int,b:int)->int:
            return a+b


        struct Point:
            x: float
            y: float
    SRC
    var once = format_source(source)
    defer: once.release()
    var twice = format_source(once.as_str())
    defer: twice.release()
    expect_eq(twice.as_str(), once.as_str())


@[test]
function test_empty_source_formats_to_a_newline() -> void:
    ## The host's pretty printer always ends with a newline, including for an
    ## empty file; the CST modes leave an empty file empty.
    var formatted = format_source_with_comments("")
    defer: formatted.release()
    expect_eq(formatted.as_str(), "\n")


@[test]
function test_already_formatted_is_stable() -> void:
    ## Canonical input should round-trip unchanged.
    var source = <<-SRC
        function main() -> int:
            return 0
    SRC
    var once = format_source(source)
    defer: once.release()
    var twice = format_source(once.as_str())
    defer: twice.release()
    expect_eq(once.as_str(), twice.as_str())

# =============================================================================
#  Normalization
# =============================================================================


@[test]
function test_normalizes_param_and_operator_spacing() -> void:
    var source = <<-SRC
        function add(a:int,b:int)->int:
            return a+b
    SRC
    var formatted = format_source(source)
    defer: formatted.release()
    let text = formatted.as_str()
    expect_contains(text, "function add(a: int, b: int) -> int:")
    expect_contains(text, "return a + b")
    return


@[test]
function test_collapses_extra_blank_lines() -> void:
    ## Multiple consecutive blank lines between declarations collapse to the
    ## canonical single separator; there must be no triple newline.
    var source = <<-SRC
        function a() -> int:
            return 1




        function b() -> int:
            return 2
    SRC
    var formatted = format_source(source)
    defer: formatted.release()
    let text = formatted.as_str()
    expect_contains(text, "function a() -> int:")
    expect_contains(text, "function b() -> int:")
    expect(not text.contains_substring("\n\n\n"))


@[test]
function test_preserves_struct_fields() -> void:
    var source = <<-SRC
        struct Vec2:
            x: float
            y: float
    SRC
    var formatted = format_source(source)
    defer: formatted.release()
    let text = formatted.as_str()
    expect_contains(text, "struct Vec2:")
    expect_contains(text, "    x: float")
    expect_contains(text, "    y: float")
    return


@[test]
function test_preserves_enum_members() -> void:
    var source = <<-SRC
        enum Color: ubyte
            red = 0
            green = 1
    SRC
    var formatted = format_source(source)
    defer: formatted.release()
    let text = formatted.as_str()
    expect_contains(text, "enum Color: ubyte")
    expect_contains(text, "red = 0")
    expect_contains(text, "green = 1")
    return


@[test]
function test_formats_match_statement() -> void:
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
    defer: formatted.release()
    let text = formatted.as_str()
    expect_contains(text, "match s:")
    expect_contains(text, "State.idle:")
    expect_contains(text, "State.busy:")
    return

# =============================================================================
#  Comment reattachment (host goldens from `PrettyPrinter.format_ast`)
# =============================================================================

function expect_formatted_with_comments(source: str, expected: str) -> void:
    var formatted = format_source_with_comments(source)
    defer: formatted.release()
    expect_eq(formatted.as_str(), expected)


@[test]
function test_reattaches_leading_and_inline_comments() -> void:
    let source = "# top comment\nfunction demo(a: int) -> int:\n    let x = a  # trailing let\n    return x\n"
    expect_formatted_with_comments(source, source)


@[test]
function test_reattaches_comment_before_declaration() -> void:
    let source = "# before\nstruct Point:\n    x: float\n"
    expect_formatted_with_comments(source, source)


@[test]
function test_comment_blocks_unsafe_collapse() -> void:
    let source = "function control() -> void:\n    unsafe:\n        # explanation\n        pass\n    return\n"
    expect_formatted_with_comments(source, source)


@[test]
function test_unsafe_still_collapses_without_comment() -> void:
    let source = "function control() -> void:\n    unsafe:\n        pass\n    return\n"
    let expected = "function control() -> void:\n    unsafe: pass\n    return\n"
    expect_formatted_with_comments(source, expected)


@[test]
function test_flushes_trailing_comment() -> void:
    let source = "function demo() -> void:\n    pass\n# final comment\n"
    expect_formatted_with_comments(source, source)


@[test]
function test_plain_parse_still_drops_comments() -> void:
    ## `mtc parse` (the trivia-free entry) must keep omitting comments.
    let source = "# top comment\nfunction demo() -> void:\n    pass\n"
    var formatted = format_source(source)
    defer: formatted.release()
    expect_eq(int<-(formatted.as_str().len), int<-("function demo() -> void:\n    pass\n".len))

# =============================================================================
#  Format strings (`f"..."` arguments and specs)
# =============================================================================


@[test]
function test_renders_format_string_arguments() -> void:
    let source = "function draw(text: str) -> void:\n    pass\n\nfunction main() -> int:\n    let a = 1\n    draw(f\"x = #{a}\")\n    draw(f\"plain\")\n    return 0\n"
    var formatted = format_source(source)
    defer: formatted.release()
    let text = formatted.as_str()
    expect_contains(text, "draw(f\"x = #{a}\")")
    expect_contains(text, "draw(f\"plain\")")


@[test]
function test_renders_format_specs() -> void:
    let source = "function main(v: int) -> int:\n    let s = f\"v=#{v:.2} h=#{v:x} H=#{v:X}\"\n    return v\n"
    var formatted = format_source(source)
    defer: formatted.release()
    expect_contains(formatted.as_str(), "f\"v=#{v:.2} h=#{v:x} H=#{v:X}\"")
