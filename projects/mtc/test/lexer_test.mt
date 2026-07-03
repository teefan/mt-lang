# In-language lexer tests for the self-hosted mtc compiler.
# Run with: mtc test projects/mtc

import std.testing as t
import std.vec as vec
import mtc.lexer.token_kinds as tk
import mtc.lexer.token as token_mod
import mtc.lexer.keywords as keywords
import mtc.lexer.lexer as lexer


@[test]
function test_keyword_lookup() -> t.Check:
    let kind = keywords.keyword_kind("if")
    if kind != tk.TokenKind.tk_if:
        return t.fail("expected token kind tk_if")
    return t.ok()


@[test]
function test_keyword_lookup_unknown() -> t.Check:
    let kind = keywords.keyword_kind("my_identifier")
    if kind != tk.TokenKind.identifier:
        return t.fail("expected token kind identifier")
    return t.ok()


@[test]
function test_basic_lexing() -> t.Check:
    let source= <<-SRC
        let x = 42
    SRC
    var tokens = lexer.lex(source)
    t.expect(tokens.len() == 6z, "should produce 6 tokens")?
    return t.ok()


@[test]
function test_numbers_lexing() -> t.Check:
    let source= <<-SRC
        0xff 0b1010 3.14 42u
    SRC
    var tokens = lexer.lex(source)
    t.expect(tokens.len() == 6z, "should produce 6 tokens")?
    return t.ok()


@[test]
function test_indentation_lexing() -> t.Check:
    let source= <<-SRC
        if true:
            x
        else:
            y
    SRC
    var tokens = lexer.lex(source)
    t.expect(tokens.len() == 16z, "should produce 16 tokens")?
    return t.ok()


@[test]
function test_operators_lexing() -> t.Check:
    let source= <<-SRC
        a + b << c == d
    SRC
    var tokens = lexer.lex(source)
    t.expect(tokens.len() == 9z, "should produce 9 tokens")?
    return t.ok()


@[test]
function test_function_lexing() -> t.Check:
    let source= <<-SRC
        function main() -> int:
            return 0
    SRC
    var tokens = lexer.lex(source)
    t.expect(tokens.len() == 14z, "should produce 14 tokens")?
    return t.ok()


@[test]
function test_adjacent_strings_merge() -> t.Check:
    let source= <<-SRC
        const title = "hello "
            "world"
    SRC
    var tokens = lexer.lex(source)
    var string_count = count_by_kind(ref_of(tokens), tk.TokenKind.string)
    t.expect(string_count == 1, "adjacent strings should merge into 1 token")?
    return t.ok()


@[test]
function test_same_level_strings_do_not_merge() -> t.Check:
    let source= <<-SRC
        "one"
        "two"
    SRC
    var tokens = lexer.lex(source)
    var string_count = count_by_kind(ref_of(tokens), tk.TokenKind.string)
    t.expect(string_count == 2, "same-indent strings should not merge")?
    return t.ok()


@[test]
function test_adjacent_cstrings_merge() -> t.Check:
    let source= <<-SRC
        const s: cstr = c"alpha"
            c" beta"
            c" gamma"
    SRC
    var tokens = lexer.lex(source)
    var cstring_count = count_by_kind(ref_of(tokens), tk.TokenKind.cstring)
    t.expect(cstring_count == 1, "adjacent c-strings should merge into 1 token")?
    return t.ok()


@[test]
function test_string_escape_sequences() -> t.Check:
    let source= <<-SRC
        "hello\nworld"
    SRC
    var tokens = lexer.lex(source)
    t.expect(tokens.len() >= 3z, "should have string + newline + eof")?
    return t.ok()


@[test]
function test_char_literal_normal() -> t.Check:
    let source= <<-SRC
        'a'
    SRC
    var tokens = lexer.lex(source)
    t.expect(tokens.len() >= 3z, "should have char_literal + newline + eof")?
    return t.ok()


@[test]
function test_char_literal_escape() -> t.Check:
    let source= <<-SRC
        '\n'
    SRC
    var tokens = lexer.lex(source)
    t.expect(tokens.len() >= 3z, "should have char_literal + newline + eof")?
    return t.ok()


@[test]
function test_char_literal_hex_escape() -> t.Check:
    let source= <<-SRC
        '\x41'
    SRC
    var tokens = lexer.lex(source)
    t.expect(tokens.len() >= 3z, "should have char_literal + newline + eof")?
    return t.ok()


@[test]
function test_line_continuation_suppresses_newline() -> t.Check:
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
                return t.fail("dot_dot should suppress following newline")
        i += 1
    return t.ok()


@[test]
function test_integer_suffixes() -> t.Check:
    let source= <<-SRC
        42ub 100z 7i
    SRC
    var tokens = lexer.lex(source)
    var int_count = count_by_kind(ref_of(tokens), tk.TokenKind.integer)
    t.expect(int_count == 3, "should have 3 integer tokens with suffixes")?
    return t.ok()


@[test]
function test_basic_heredoc() -> t.Check:
    let source= <<-SRC
        const text = <<-TEXT
            alpha
              beta
        TEXT
    SRC
    var tokens = lexer.lex(source)
    t.expect(count_by_kind(ref_of(tokens), tk.TokenKind.string) == 1, "heredoc should produce 1 string token")?
    return t.ok()


@[test]
function test_cstring_heredoc() -> t.Check:
    let source= <<-SRC
        const shader = c<<-GLSL
            void main() {}
        GLSL
    SRC
    var tokens = lexer.lex(source)
    t.expect(count_by_kind(ref_of(tokens), tk.TokenKind.cstring) == 1, "c-heredoc should produce 1 cstring token")?
    return t.ok()


@[test]
function test_basic_format_string() -> t.Check:
    let source= <<-SRC
        const msg = f"count=#{42}"
    SRC
    var tokens = lexer.lex(source)
    t.expect(count_by_kind(ref_of(tokens), tk.TokenKind.fstring) == 1, "fstring should produce 1 fstring token")?
    return t.ok()


@[test]
function test_format_string_with_nested_braces() -> t.Check:
    let source= <<-SRC
        f"nested=#{if flag: 1 else: 2}"
    SRC
    var tokens = lexer.lex(source)
    t.expect(count_by_kind(ref_of(tokens), tk.TokenKind.fstring) == 1, "fstring with nested braces should lex")?
    return t.ok()


@[test]
function test_cstring_literal() -> t.Check:
    let source= <<-SRC
        c"hello"
    SRC
    var tokens = lexer.lex(source)
    t.expect(count_by_kind(ref_of(tokens), tk.TokenKind.string) == 0, "c\"...\" should not produce a regular string token")?
    t.expect(count_by_kind(ref_of(tokens), tk.TokenKind.cstring) == 1, "c\"...\" should produce 1 cstring token")?
    return t.ok()


@[test]
function test_format_heredoc() -> t.Check:
    let source= <<-SRC
        const msg = f<<-FMT
            value=#{count}
        FMT
    SRC
    var tokens = lexer.lex(source)
    t.expect(count_by_kind(ref_of(tokens), tk.TokenKind.fstring) == 1, "format-heredoc should produce 1 fstring token")?
    return t.ok()


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
