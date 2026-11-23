# In-language lexer tests for the self-hosted mtc compiler.
# Run with: mtc test projects/mtc

import std.vec as vec
import mtc.lexer.token_kinds as tk
import mtc.lexer.token as token_mod
import mtc.lexer.keywords as keywords
import mtc.lexer.lexer as lexer


@[test]
function test_keyword_lookup() -> void:
    let kind = keywords.keyword_kind("if")
    if kind != tk.TokenKind.tk_if:
        expect(false, "expected token kind tk_if")
    return


@[test]
function test_keyword_lookup_unknown() -> void:
    let kind = keywords.keyword_kind("my_identifier")
    if kind != tk.TokenKind.identifier:
        expect(false, "expected token kind identifier")
    return


@[test]
function test_basic_lexing() -> void:
    let source= <<-SRC
        let x = 42
    SRC
    var tokens = lexer.lex(source)
    expect(tokens.len() == 6, "should produce 6 tokens")
    return


@[test]
function test_numbers_lexing() -> void:
    let source= <<-SRC
        0xff 0b1010 3.14 42u
    SRC
    var tokens = lexer.lex(source)
    expect(tokens.len() == 6, "should produce 6 tokens")
    return


@[test]
function test_indentation_lexing() -> void:
    let source= <<-SRC
        if true:
            x
        else:
            y
    SRC
    var tokens = lexer.lex(source)
    expect(tokens.len() == 16, "should produce 16 tokens")
    return


@[test]
function test_operators_lexing() -> void:
    let source= <<-SRC
        a + b << c == d
    SRC
    var tokens = lexer.lex(source)
    expect(tokens.len() == 9, "should produce 9 tokens")
    return


@[test]
function test_function_lexing() -> void:
    let source= <<-SRC
        function main() -> int:
            return 0
    SRC
    var tokens = lexer.lex(source)
    expect(tokens.len() == 14, "should produce 14 tokens")
    return


@[test]
function test_adjacent_strings_merge() -> void:
    let source= <<-SRC
        const title = "hello "
            "world"
    SRC
    var tokens = lexer.lex(source)
    var string_count = count_by_kind(ref_of(tokens), tk.TokenKind.string)
    expect(string_count == 1, "adjacent strings should merge into 1 token")
    return


@[test]
function test_same_level_strings_do_not_merge() -> void:
    let source= <<-SRC
        "one"
        "two"
    SRC
    var tokens = lexer.lex(source)
    var string_count = count_by_kind(ref_of(tokens), tk.TokenKind.string)
    expect(string_count == 2, "same-indent strings should not merge")
    return


@[test]
function test_adjacent_cstrings_merge() -> void:
    let source= <<-SRC
        const s: cstr = c"alpha"
            c" beta"
            c" gamma"
    SRC
    var tokens = lexer.lex(source)
    var cstring_count = count_by_kind(ref_of(tokens), tk.TokenKind.cstring)
    expect(cstring_count == 1, "adjacent c-strings should merge into 1 token")
    return


@[test]
function test_string_escape_sequences() -> void:
    let source= <<-SRC
        "hello\nworld"
    SRC
    var tokens = lexer.lex(source)
    expect(tokens.len() >= 3, "should have string + newline + eof")
    return


@[test]
function test_char_literal_normal() -> void:
    let source= <<-SRC
        'a'
    SRC
    var tokens = lexer.lex(source)
    expect(tokens.len() >= 3, "should have char_literal + newline + eof")
    return


@[test]
function test_char_literal_escape() -> void:
    let source= <<-SRC
        '\n'
    SRC
    var tokens = lexer.lex(source)
    expect(tokens.len() >= 3, "should have char_literal + newline + eof")
    return


@[test]
function test_char_literal_hex_escape() -> void:
    let source= <<-SRC
        '\x41'
    SRC
    var tokens = lexer.lex(source)
    expect(tokens.len() >= 3, "should have char_literal + newline + eof")
    return


@[test]
function test_line_continuation_suppresses_newline() -> void:
    let source= <<-SRC
        let values = 1 ..
            4
    SRC
    var tokens = lexer.lex(source)
    var i: ptr_uint = 0
    while i + 1 < tokens.len():
        let tok = tokens.get(i) else:
            break
        let next_tok = tokens.get(i + 1) else:
            break
        unsafe:
            if read(tok).kind == tk.TokenKind.dot_dot and read(next_tok).kind == tk.TokenKind.newline:
                expect(false, "dot_dot should suppress following newline")
        i += 1
    return


@[test]
function test_integer_suffixes() -> void:
    let source= <<-SRC
        42ub 100z 7i
    SRC
    var tokens = lexer.lex(source)
    var int_count = count_by_kind(ref_of(tokens), tk.TokenKind.integer)
    expect(int_count == 3, "should have 3 integer tokens with suffixes")
    return


@[test]
function test_basic_heredoc() -> void:
    let source= <<-SRC
        const text = <<-TEXT
            alpha
              beta
        TEXT
    SRC
    var tokens = lexer.lex(source)
    expect(count_by_kind(ref_of(tokens), tk.TokenKind.string) == 1, "heredoc should produce 1 string token")
    return


@[test]
function test_cstring_heredoc() -> void:
    let source= <<-SRC
        const shader = c<<-GLSL
            void main() {}
        GLSL
    SRC
    var tokens = lexer.lex(source)
    expect(count_by_kind(ref_of(tokens), tk.TokenKind.cstring) == 1, "c-heredoc should produce 1 cstring token")
    return


@[test]
function test_basic_format_string() -> void:
    let source= <<-SRC
        const msg = f"count=#{42}"
    SRC
    var tokens = lexer.lex(source)
    expect(count_by_kind(ref_of(tokens), tk.TokenKind.fstring) == 1, "fstring should produce 1 fstring token")
    return


@[test]
function test_format_string_with_nested_braces() -> void:
    let source= <<-SRC
        f"nested=#{if flag: 1 else: 2}"
    SRC
    var tokens = lexer.lex(source)
    expect(count_by_kind(ref_of(tokens), tk.TokenKind.fstring) == 1, "fstring with nested braces should lex")
    return


@[test]
function test_cstring_literal() -> void:
    let source= <<-SRC
        c"hello"
    SRC
    var tokens = lexer.lex(source)
    expect(count_by_kind(ref_of(tokens), tk.TokenKind.string) == 0, "c\"...\" should not produce a regular string token")
    expect(count_by_kind(ref_of(tokens), tk.TokenKind.cstring) == 1, "c\"...\" should produce 1 cstring token")
    return


@[test]
function test_format_heredoc() -> void:
    let source= <<-SRC
        const msg = f<<-FMT
            value=#{count}
        FMT
    SRC
    var tokens = lexer.lex(source)
    expect(count_by_kind(ref_of(tokens), tk.TokenKind.fstring) == 1, "format-heredoc should produce 1 fstring token")
    return


@[test]
function test_float_scientific_notation() -> void:
    let source= <<-SRC
        1e10 2E-3 3.14e2
    SRC
    var tokens = lexer.lex(source)
    var fc = count_by_kind(ref_of(tokens), tk.TokenKind.float_literal)
    expect(fc == 3, "should have 3 float tokens")
    return


@[test]
function test_float_with_suffix() -> void:
    let source= <<-SRC
        1.0f 2.0d
    SRC
    var tokens = lexer.lex(source)
    var fc = count_by_kind(ref_of(tokens), tk.TokenKind.float_literal)
    expect(fc == 2, "should have 2 float tokens with suffix")
    return


@[test]
function test_integer_underscore_separator() -> void:
    let source= <<-SRC
        1_000_000 0xff_ff
    SRC
    var tokens = lexer.lex(source)
    var ic = count_by_kind(ref_of(tokens), tk.TokenKind.integer)
    expect(ic == 2, "should have 2 integer tokens")
    return


@[test]
function test_comment_skipped() -> void:
    let source= <<-SRC
        # this is a comment
        let x = 1
    SRC
    var tokens = lexer.lex(source)
    expect(count_by_kind(ref_of(tokens), tk.TokenKind.tk_let) == 1, "let should be present")
    return


@[test]
function test_doc_comment_skipped() -> void:
    let source= <<-SRC
        ## doc comment
        let x = 1
    SRC
    var tokens = lexer.lex(source)
    expect(count_by_kind(ref_of(tokens), tk.TokenKind.tk_let) == 1, "doc comment should be skipped")
    return


@[test]
function test_blank_lines_skipped() -> void:
    let source= <<-SRC

        let x = 1

    SRC
    var tokens = lexer.lex(source)
    expect(count_by_kind(ref_of(tokens), tk.TokenKind.tk_let) == 1, "blank lines should be skipped")
    return


@[test]
function test_crlf_handling() -> void:
    let source = "function main() -> int:\r\n    return 0"
    var tokens = lexer.lex(source)
    expect(tokens.len() >= 5, "should handle CRLF line endings")
    return


@[test]
function test_keyword_boundary() -> void:
    let source= <<-SRC
        ifx while_ forx else_if
    SRC
    var tokens = lexer.lex(source)
    var ic = count_by_kind(ref_of(tokens), tk.TokenKind.identifier)
    expect(ic == 4, "keyword-prefixed identifiers should be identifiers")
    return


@[test]
function test_hex_integer_mixed_case() -> void:
    let source= <<-SRC
        0xAb 0xFF 0Xff
    SRC
    var tokens = lexer.lex(source)
    var ic = count_by_kind(ref_of(tokens), tk.TokenKind.integer)
    expect(ic == 3, "hex with mixed case should all be integers")
    return


@[test]
function test_empty_source() -> void:
    var tokens = lexer.lex("")
    expect(tokens.len() == 1, "empty source should produce only eof")
    return


@[test]
function test_lex_reporting_collects_errors() -> void:
    let source = "function f() -> int:\n\t\treturn 0"
    var diags = vec.Vec[token_mod.LexDiagnostic].create()
    var tokens = lexer.lex_reporting(source, ref_of(diags))
    var has_tab_error = false
    var di: ptr_uint = 0
    while di < diags.len():
        let d = diags.get(di) else:
            break
        unsafe:
            if read(d).message == c"tabs are not allowed; use 4 spaces for indentation":
                has_tab_error = true
        di += 1
    diags.release()
    expect(has_tab_error, "should report tab error")
    return


@[test]
function test_lex_reporting_unterminated_string() -> void:
    let source = "\"hello"
    var diags = vec.Vec[token_mod.LexDiagnostic].create()
    var tokens = lexer.lex_reporting(source, ref_of(diags))
    var has_error = diags.len() > 0
    diags.release()
    expect(has_error, "unterminated string should produce lex error")
    return


@[test]
function test_lex_reporting_unexpected_char() -> void:
    let source = "`"
    var diags = vec.Vec[token_mod.LexDiagnostic].create()
    var tokens = lexer.lex_reporting(source, ref_of(diags))
    var has_error = diags.len() > 0
    diags.release()
    expect(has_error, "unexpected char should produce lex error")
    return


@[test]
function test_lex_reporting_unclosed_grouping() -> void:
    let source = "function f() -> int:\n    g("
    var diags = vec.Vec[token_mod.LexDiagnostic].create()
    var tokens = lexer.lex_reporting(source, ref_of(diags))
    var has_error = diags.len() > 0
    diags.release()
    expect(has_error, "unclosed paren should produce lex error")
    return


# ── helpers ──

function count_by_kind(tokens: ref[vec.Vec[token_mod.Token]], kind: tk.TokenKind) -> int:
    var count: int = 0
    var i: ptr_uint = 0
    while i < tokens.len():
        let tok = tokens.get(i) else:
            break
        unsafe:
            if read(tok).kind == kind:
                count += 1
        i += 1
    return count
