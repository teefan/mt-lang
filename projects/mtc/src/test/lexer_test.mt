## Lexer regression tests.
##
## Run with: mtc test projects/mtc/test/

import std.testing as t
import std.str

import lexer.lexer as lexer_mod

# ── keywords ──────────────────────────────────────────────────────────────

@[test]
public function test_keywords_are_recognized() -> t.Check:
    let source = "function return if else while for match const var let type struct enum"
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(output.contains_substring("\"type\":\"function\""), "function keyword")?
    t.expect(output.contains_substring("\"type\":\"return\""), "return keyword")?
    t.expect(output.contains_substring("\"type\":\"if\""), "if keyword")?
    t.expect(output.contains_substring("\"type\":\"else\""), "else keyword")?
    t.expect(output.contains_substring("\"type\":\"while\""), "while keyword")?
    t.expect(output.contains_substring("\"type\":\"for\""), "for keyword")?
    t.expect(output.contains_substring("\"type\":\"match\""), "match keyword")?
    t.expect(output.contains_substring("\"type\":\"const\""), "const keyword")?
    t.expect(output.contains_substring("\"type\":\"var\""), "var keyword")?
    t.expect(output.contains_substring("\"type\":\"let\""), "let keyword")?
    t.expect(output.contains_substring("\"type\":\"type\""), "type keyword")?
    t.expect(output.contains_substring("\"type\":\"struct\""), "struct keyword")?
    t.expect(output.contains_substring("\"type\":\"enum\""), "enum keyword")?

    json.release()
    return t.ok()

@[test]
public function test_bool_and_null_literals() -> t.Check:
    let source = "true false null"
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(output.contains_substring("\"literal\":true"), "true literal")?
    t.expect(output.contains_substring("\"literal\":false"), "false literal")?
    t.expect(output.contains_substring("\"literal\":null"), "null literal")?

    json.release()
    return t.ok()

# ── numeric literals ──────────────────────────────────────────────────────

@[test]
public function test_integer_literals() -> t.Check:
    let source = "0 42 0xff 0b1010 1_000_000 42u 0xFFub 100z"
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(output.contains_substring("\"lexeme\":\"0\""), "zero")?
    t.expect(output.contains_substring("\"lexeme\":\"42\""), "decimal")?
    t.expect(output.contains_substring("\"lexeme\":\"0xff\""), "hex")?
    t.expect(output.contains_substring("\"lexeme\":\"0b1010\""), "binary")?
    t.expect(output.contains_substring("\"lexeme\":\"1_000_000\""), "underscore sep")?
    t.expect(output.contains_substring("\"lexeme\":\"42u\""), "u suffix")?
    t.expect(output.contains_substring("\"lexeme\":\"0xFFub\""), "ub suffix")?
    t.expect(output.contains_substring("\"lexeme\":\"100z\""), "z suffix")?

    json.release()
    return t.ok()

@[test]
public function test_float_literals() -> t.Check:
    let source = "3.14 1.2e-3 1.0f 1.0d 1.1920929E-7"
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(output.contains_substring("\"type\":\"float\",\"lexeme\":\"3.14\""), "simple float")?
    t.expect(output.contains_substring("\"lexeme\":\"1.2e-3\""), "sci notation")?
    t.expect(output.contains_substring("\"lexeme\":\"1.0f\""), "f suffix")?
    t.expect(output.contains_substring("\"lexeme\":\"1.0d\""), "d suffix")?
    t.expect(output.contains_substring("\"lexeme\":\"1.1920929E-7\""), "upper E sci")?

    json.release()
    return t.ok()

# ── char literals ─────────────────────────────────────────────────────────

@[test]
public function test_char_literals() -> t.Check:
    let source = "'a' '\\n' '\\t' '\\\\' '\\'' '\\0' '\\x41'"
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(output.contains_substring("\"type\":\"char_literal\""), "char literal type")?
    t.expect(output.contains_substring("\"lexeme\":\"'a'\""), "char a")?
    t.expect(output.contains_substring("\"lexeme\":\"'\\\\n'\""), "char newline")?
    t.expect(output.contains_substring("\"lexeme\":\"'\\\\t'\""), "char tab")?
    t.expect(output.contains_substring("\"lexeme\":\"'\\\\\\\\'\""), "char backslash")?
    t.expect(output.contains_substring("\"lexeme\":\"'\\\\''\""), "char single quote")?
    t.expect(output.contains_substring("\"lexeme\":\"'\\\\0'\""), "char null")?
    t.expect(output.contains_substring("\"lexeme\":\"'\\\\x41'\""), "char hex")?

    json.release()
    return t.ok()

# ── strings ───────────────────────────────────────────────────────────────

@[test]
public function test_string_literal_escapes() -> t.Check:
    let source = "\"hello\\nworld\\ttab\\\\quote\\\"end\""
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(output.contains_substring("\"type\":\"string\""), "string type")?
    t.expect(output.contains_substring("hello"), "hello content")?
    t.expect(output.contains_substring("world"), "world content")?

    json.release()
    return t.ok()

@[test]
public function test_cstring_literal() -> t.Check:
    let source = "c\"hello from C\""
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(output.contains_substring("\"type\":\"cstring\""), "cstring type")?
    t.expect(output.contains_substring("hello from C"), "cstring content")?

    json.release()
    return t.ok()

# ── heredocs ──────────────────────────────────────────────────────────────

@[test]
public function test_heredoc_cstring() -> t.Check:
    let source = "const X: cstr = c<<-TAG\n    hello world\nTAG"
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(output.contains_substring("\"type\":\"cstring\""), "cstring heredoc type")?
    t.expect(output.contains_substring("hello world"), "heredoc cstring content")?

    json.release()
    return t.ok()

@[test]
public function test_heredoc_string() -> t.Check:
    let source = "const X: str = <<-TAG\n    content line\nTAG"
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(output.contains_substring("\"type\":\"string\""), "string heredoc type")?
    t.expect(output.contains_substring("content line"), "heredoc string content")?

    json.release()
    return t.ok()

# ── format strings ────────────────────────────────────────────────────────

@[test]
public function test_format_string() -> t.Check:
    let source = "f\"count=#{42} label=#{name}\""
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(output.contains_substring("\"type\":\"fstring\""), "fstring type")?
    t.expect(output.contains_substring("\"kind\":\"text\""), "has text part")?
    t.expect(output.contains_substring("\"kind\":\"expr\""), "has expr part")?

    json.release()
    return t.ok()

# ── operators ─────────────────────────────────────────────────────────────

@[test]
public function test_operators() -> t.Check:
    let source = "+ - * / % = == != < <= > >= << >> <<= >>= -> .. ... & | ^ ~ @ ?"
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(output.contains_substring("\"type\":\"ellipsis\",\"lexeme\":\"...\""), "ellipsis")?
    t.expect(output.contains_substring("\"type\":\"arrow\",\"lexeme\":\"->\""), "arrow")?
    t.expect(output.contains_substring("\"type\":\"dot_dot\",\"lexeme\":\"..\""), "dot dot")?
    t.expect(output.contains_substring("\"type\":\"at\",\"lexeme\":\"@\""), "at")?
    t.expect(output.contains_substring("\"type\":\"question\",\"lexeme\":\"?\""), "question")?

    json.release()
    return t.ok()

@[test]
public function test_assignment_operators() -> t.Check:
    let source = "x += 1 -= 2 *= 3 /= 4 %= 5 &= 6 |= 7 ^= 8 <<= 1 >>= 1"
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(output.contains_substring("\"type\":\"plus_equal\""), "+=")?
    t.expect(output.contains_substring("\"type\":\"minus_equal\""), "-=")?
    t.expect(output.contains_substring("\"type\":\"star_equal\""), "*=")?
    t.expect(output.contains_substring("\"type\":\"slash_equal\""), "/=")?
    t.expect(output.contains_substring("\"type\":\"percent_equal\""), "%=")?
    t.expect(output.contains_substring("\"type\":\"amp_equal\""), "&=")?
    t.expect(output.contains_substring("\"type\":\"pipe_equal\""), "|=")?
    t.expect(output.contains_substring("\"type\":\"caret_equal\""), "^=")?
    t.expect(output.contains_substring("\"type\":\"shift_left_equal\""), "<<=")?
    t.expect(output.contains_substring("\"type\":\"shift_right_equal\""), ">>=")?

    json.release()
    return t.ok()

# ── indentation ───────────────────────────────────────────────────────────

@[test]
public function test_indentation_increases() -> t.Check:
    let source = <<-SRC
function f() -> int:
    return 1
SRC
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(output.contains_substring("\"type\":\"indent\""), "has indent")?
    t.expect(output.contains_substring("\"type\":\"return\""), "has return")?
    t.expect(output.contains_substring("\"type\":\"dedent\""), "has dedent")?

    json.release()
    return t.ok()

@[test]
public function test_grouping_suppresses_newlines() -> t.Check:
    let source = <<-SRC
f(
    1,
    2
)
SRC
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(output.contains_substring("\"type\":\"lparen\""), "has lparen")?
    t.expect(output.contains_substring("\"lexeme\":\"1\""), "has 1")?
    t.expect(output.contains_substring("\"lexeme\":\"2\""), "has 2")?
    t.expect(output.contains_substring("\"type\":\"rparen\""), "has rparen")?

    json.release()
    return t.ok()

# ── line continuation ─────────────────────────────────────────────────────

@[test]
public function test_line_continuation() -> t.Check:
    let source = <<-SRC
let x = 1 +
    2
SRC
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(output.contains_substring("\"type\":\"plus\""), "has plus")?
    t.expect(output.contains_substring("\"lexeme\":\"2\""), "has 2")?

    json.release()
    return t.ok()

# ── comments ──────────────────────────────────────────────────────────────

@[test]
public function test_comments_are_skipped() -> t.Check:
    let source = <<-SRC
x # this is a comment
y
SRC
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(not output.contains_substring("comment"), "comment text absent")?
    t.expect(output.contains_substring("\"lexeme\":\"x\""), "has x")?
    t.expect(output.contains_substring("\"lexeme\":\"y\""), "has y")?

    json.release()
    return t.ok()

@[test]
public function test_comment_only_source() -> t.Check:
    let source = <<-SRC
# this is a comment
# another comment
SRC
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(not output.contains_substring("comment"), "comment text absent")?
    t.expect(output.contains_substring("\"type\":\"eof\""), "has eof")?

    json.release()
    return t.ok()

# ── edge cases ────────────────────────────────────────────────────────────

@[test]
public function test_empty_source() -> t.Check:
    let source = ""
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(output.contains_substring("\"type\":\"eof\""), "has eof")?
    t.expect(not output.contains_substring("\"type\":\"indent\""), "no indent")?

    json.release()
    return t.ok()

@[test]
public function test_adjacent_strings() -> t.Check:
    let source = <<-SRC
let x = "hello "
    "from " +
    "world"
SRC
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(output.contains_substring("hello from "), "merged content")?
    t.expect(output.contains_substring("world"), "separate world")?

    json.release()
    return t.ok()

@[test]
public function test_parallel_keyword() -> t.Check:
    let source = "parallel for i in 0..4:\n    x[i] += 1"
    var json = lexer_mod.lex_to_json(source)
    let output = json.as_str()

    t.expect(output.contains_substring("\"type\":\"parallel\""), "parallel keyword")?
    t.expect(output.contains_substring("\"type\":\"for\""), "for keyword")?
    t.expect(output.contains_substring("\"type\":\"colon\""), "colon")?

    json.release()
    return t.ok()
