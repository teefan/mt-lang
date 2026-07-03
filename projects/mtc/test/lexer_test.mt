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
    var tokens = lexer.lex("let x = 42\n")
    t.expect(tokens.len() == 6z, "should produce 6 tokens")?
    return t.ok()


@[test]
function test_numbers_lexing() -> t.Check:
    var tokens = lexer.lex("0xff 0b1010 3.14 42u\n")
    t.expect(tokens.len() == 6z, "should produce 6 tokens")?
    return t.ok()


@[test]
function test_indentation_lexing() -> t.Check:
    var tokens = lexer.lex("if true:\n    x\nelse:\n    y\n")
    t.expect(tokens.len() == 16z, "should produce 16 tokens")?
    return t.ok()


@[test]
function test_operators_lexing() -> t.Check:
    var tokens = lexer.lex("a + b << c == d\n")
    t.expect(tokens.len() == 9z, "should produce 9 tokens")?
    return t.ok()


@[test]
function test_function_lexing() -> t.Check:
    var tokens = lexer.lex("function main() -> int:\n    return 0\n")
    t.expect(tokens.len() == 14z, "should produce 14 tokens")?
    return t.ok()


@[test]
function test_adjacent_strings_merge() -> t.Check:
    var tokens = lexer.lex("const title = \"hello \"\n    \"world\"\n")
    var string_count = count_by_kind(ref_of(tokens), tk.TokenKind.string)
    t.expect(string_count == 1, "adjacent strings should merge into 1 token")?
    return t.ok()


@[test]
function test_same_level_strings_do_not_merge() -> t.Check:
    var tokens = lexer.lex("\"one\"\n\"two\"\n")
    var string_count = count_by_kind(ref_of(tokens), tk.TokenKind.string)
    t.expect(string_count == 2, "same-indent strings should not merge")?
    return t.ok()


@[test]
function test_adjacent_cstrings_merge() -> t.Check:
    var tokens = lexer.lex("const s: cstr = c\"alpha\"\n    c\" beta\"\n    c\" gamma\"\n")
    var cstring_count = count_by_kind(ref_of(tokens), tk.TokenKind.cstring)
    t.expect(cstring_count == 1, "adjacent c-strings should merge into 1 token")?
    return t.ok()


@[test]
function test_string_escape_sequences() -> t.Check:
    var tokens = lexer.lex("\"hello\\nworld\"\n")
    t.expect(tokens.len() >= 3z, "should have string + newline + eof")?
    return t.ok()


@[test]
function test_char_literal_normal() -> t.Check:
    var tokens = lexer.lex("'a'\n")
    t.expect(tokens.len() >= 3z, "should have char_literal + newline + eof")?
    return t.ok()


@[test]
function test_char_literal_escape() -> t.Check:
    var tokens = lexer.lex("'\\n'\n")
    t.expect(tokens.len() >= 3z, "should have char_literal + newline + eof")?
    return t.ok()


@[test]
function test_char_literal_hex_escape() -> t.Check:
    var tokens = lexer.lex("'\\x41'\n")
    t.expect(tokens.len() >= 3z, "should have char_literal + newline + eof")?
    return t.ok()


@[test]
function test_line_continuation_suppresses_newline() -> t.Check:
    var tokens = lexer.lex("let values = 1 ..\n    4\n")
    # dot_dot should not be followed by newline
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
    var tokens = lexer.lex("42ub 100z 7i\n")
    var int_count = count_by_kind(ref_of(tokens), tk.TokenKind.integer)
    t.expect(int_count == 3, "should have 3 integer tokens with suffixes")?
    return t.ok()


@[test]
function test_basic_heredoc() -> t.Check:
    var tokens = lexer.lex("const text = <<-TEXT\n    alpha\n      beta\nTEXT\n")
    # Should produce a single string token for the heredoc
    var str_count = count_by_kind(ref_of(tokens), tk.TokenKind.string)
    t.expect(str_count == 1, "heredoc should produce 1 string token")?
    return t.ok()


@[test]
function test_cstring_heredoc() -> t.Check:
    var tokens = lexer.lex("const shader = c<<-GLSL\n    void main() {}\nGLSL\n")
    var cstr_count = count_by_kind(ref_of(tokens), tk.TokenKind.cstring)
    t.expect(cstr_count == 1, "c-heredoc should produce 1 cstring token")?
    return t.ok()


@[test]
function test_basic_format_string() -> t.Check:
    var tokens = lexer.lex("const msg = f\"count=#{42}\"\n")
    var fstr_count = count_by_kind(ref_of(tokens), tk.TokenKind.fstring)
    t.expect(fstr_count == 1, "fstring should produce 1 fstring token")?
    return t.ok()


@[test]
function test_format_string_with_nested_braces() -> t.Check:
    var tokens = lexer.lex("f\"nested=#{if flag: 1 else: 2}\"\n")
    var fstr_count = count_by_kind(ref_of(tokens), tk.TokenKind.fstring)
    t.expect(fstr_count == 1, "fstring with nested braces should lex")?
    return t.ok()


@[test]
function test_cstring_literal() -> t.Check:
    var tokens = lexer.lex("c\"hello\"\n")
    var str_count = count_by_kind(ref_of(tokens), tk.TokenKind.string)
    t.expect(str_count == 0, "c\"...\" should not produce a regular string token")?
    var cstr_count = count_by_kind(ref_of(tokens), tk.TokenKind.cstring)
    t.expect(cstr_count == 1, "c\"...\" should produce 1 cstring token")?
    return t.ok()


@[test]
function test_format_heredoc() -> t.Check:
    var tokens = lexer.lex("const msg = f<<-FMT\n    value=#{count}\nFMT\n")
    var fstr_count = count_by_kind(ref_of(tokens), tk.TokenKind.fstring)
    t.expect(fstr_count == 1, "format-heredoc should produce 1 fstring token")?
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
