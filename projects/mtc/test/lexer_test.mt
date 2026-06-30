import std.testing as t
import std.vec as vec
import lexer

# ── test source constants (heredoc avoids \n escape ambiguity) ─────────────

const SRC_KEYWORDS: str = "struct function\n"

const SRC_INTEGERS: str = <<-SRC
42
0xff
0b1010
SRC

const SRC_STRINGS: str = <<-SRC
"hello"
c"world"
SRC

const SRC_FORMAT: str = <<-SRC
f"count=#{42}"
SRC

const SRC_CHARS: str = <<-SRC
'a'
'\n'
'\x41'
SRC

const SRC_OPERATORS: str = <<-SRC
->
<<=
>>=
...
==
!=
<=
>=
<<
>>
+=
-=
*=
/=
%=
&=
|=
^=
SRC

const SRC_HEREDOC: str = <<-SRC
const shader = c<<-GLSL
    void main() {}
GLSL
SRC

const SRC_FLOATS: str = <<-SRC
3.14
1.0f
2e+3
SRC

const SRC_BOOLS: str = <<-SRC
true
false
null
SRC

const SRC_INDENT: str = <<-SRC
struct Ball:
    radius: float
SRC

const SRC_ADJACENT: str = <<-SRC
const msg = "hello "
    "world"
SRC

const SRC_ADDITIONAL_OPS: str = <<-SRC
?.
%.
+=
&=
|=
^=
~,

SRC

const SRC_SUFFIX: str = <<-SRC
0xffub
0b1010ub
SRC

const SRC_CONTINUATION: str = <<-SRC
let total = subtotal +
    tax
SRC

# ── helpers ─────────────────────────────────────────────────────────────────

function token_kind_at(tokens: ref[vec.Vec[lexer.Token]], index: ptr_uint) -> int:
    let tok = tokens.get(index) else:
        fatal("lexer_test: token index out of bounds")
    return unsafe: read(ptr[lexer.Token]<-tok).kind


function kind_at(values: ref[vec.Vec[int]], index: ptr_uint) -> int:
    let v = values.get(index) else:
        fatal("lexer_test: int index out of bounds")
    return unsafe: read(ptr[int]<-v)


function token_count(tokens: ref[vec.Vec[lexer.Token]], kind: int) -> int:
    var count: int = 0
    var i: ptr_uint = 0
    while i < tokens.len():
        let tok = tokens.get(i) else:
            fatal("lexer_test: missing token")
        unsafe:
            if read(ptr[lexer.Token]<-tok).kind == kind:
                count += 1
        i += 1
    return count


function kinds_of(tokens: ref[vec.Vec[lexer.Token]]) -> vec.Vec[int]:
    var result = vec.Vec[int].create()
    var i: ptr_uint = 0
    while i < tokens.len():
        result.push(token_kind_at(tokens, i))
        i += 1
    return result


# ── tests ───────────────────────────────────────────────────────────────────

@[test]
function test_keywords() -> t.Check:
    var errors = vec.Vec[lexer.LexError].create()
    var tokens = lexer.lex(SRC_KEYWORDS, ref_of(errors))

    t.expect_equal_int(token_kind_at(ref_of(tokens), 0), lexer.TOK_KW_STRUCT)?
    t.expect_equal_int(token_kind_at(ref_of(tokens), 1), lexer.TOK_KW_FUNCTION)?

    errors.release()
    tokens.release()
    return t.ok()


@[test]
function test_integers() -> t.Check:
    var errors = vec.Vec[lexer.LexError].create()
    var tokens = lexer.lex(SRC_INTEGERS, ref_of(errors))

    t.expect_equal_int(token_kind_at(ref_of(tokens), 0), lexer.TOK_INTEGER)?
    t.expect_equal_int(token_kind_at(ref_of(tokens), 2), lexer.TOK_INTEGER)?
    t.expect_equal_int(token_kind_at(ref_of(tokens), 4), lexer.TOK_INTEGER)?

    errors.release()
    tokens.release()
    return t.ok()


@[test]
function test_strings() -> t.Check:
    var errors = vec.Vec[lexer.LexError].create()
    var tokens = lexer.lex(SRC_STRINGS, ref_of(errors))

    t.expect_equal_int(token_kind_at(ref_of(tokens), 0), lexer.TOK_STRING)?
    t.expect_equal_int(token_kind_at(ref_of(tokens), 2), lexer.TOK_CSTRING)?

    errors.release()
    tokens.release()
    return t.ok()


@[test]
function test_format_string() -> t.Check:
    var errors = vec.Vec[lexer.LexError].create()
    var tokens = lexer.lex(SRC_FORMAT, ref_of(errors))

    t.expect_equal_int(token_kind_at(ref_of(tokens), 0), lexer.TOK_FSTRING)?

    errors.release()
    tokens.release()
    return t.ok()


@[test]
function test_char_literals() -> t.Check:
    var errors = vec.Vec[lexer.LexError].create()
    var tokens = lexer.lex(SRC_CHARS, ref_of(errors))

    t.expect_equal_int(token_kind_at(ref_of(tokens), 0), lexer.TOK_CHAR_LITERAL)?
    t.expect_equal_int(token_kind_at(ref_of(tokens), 2), lexer.TOK_CHAR_LITERAL)?
    t.expect_equal_int(token_kind_at(ref_of(tokens), 4), lexer.TOK_CHAR_LITERAL)?

    errors.release()
    tokens.release()
    return t.ok()


@[test]
function test_operators() -> t.Check:
    var errors = vec.Vec[lexer.LexError].create()
    var tokens = lexer.lex(SRC_OPERATORS, ref_of(errors))
    var kinds = kinds_of(ref_of(tokens))

    t.expect_equal_int(kind_at(ref_of(kinds), 0), lexer.TOK_ARROW)?
    t.expect_equal_int(kind_at(ref_of(kinds), 2), lexer.TOK_SHIFT_LEFT_EQUAL)?
    t.expect_equal_int(kind_at(ref_of(kinds), 4), lexer.TOK_SHIFT_RIGHT_EQUAL)?
    t.expect_equal_int(kind_at(ref_of(kinds), 6), lexer.TOK_ELLIPSIS)?
    t.expect_equal_int(kind_at(ref_of(kinds), 8), lexer.TOK_EQUAL_EQUAL)?
    t.expect_equal_int(kind_at(ref_of(kinds), 9), lexer.TOK_BANG_EQUAL)?
    t.expect_equal_int(kind_at(ref_of(kinds), 10), lexer.TOK_LESS_EQUAL)?
    t.expect_equal_int(kind_at(ref_of(kinds), 11), lexer.TOK_GREATER_EQUAL)?
    t.expect_equal_int(kind_at(ref_of(kinds), 12), lexer.TOK_SHIFT_LEFT)?
    t.expect_equal_int(kind_at(ref_of(kinds), 13), lexer.TOK_SHIFT_RIGHT)?
    t.expect_equal_int(kind_at(ref_of(kinds), 14), lexer.TOK_PLUS_EQUAL)?
    t.expect_equal_int(kind_at(ref_of(kinds), 16), lexer.TOK_MINUS_EQUAL)?
    t.expect_equal_int(kind_at(ref_of(kinds), 18), lexer.TOK_STAR_EQUAL)?
    t.expect_equal_int(kind_at(ref_of(kinds), 20), lexer.TOK_SLASH_EQUAL)?
    t.expect_equal_int(kind_at(ref_of(kinds), 22), lexer.TOK_PERCENT_EQUAL)?
    t.expect_equal_int(kind_at(ref_of(kinds), 24), lexer.TOK_AMP_EQUAL)?
    t.expect_equal_int(kind_at(ref_of(kinds), 26), lexer.TOK_PIPE_EQUAL)?
    t.expect_equal_int(kind_at(ref_of(kinds), 28), lexer.TOK_CARET_EQUAL)?

    kinds.release()
    errors.release()
    tokens.release()
    return t.ok()


@[test]
function test_heredoc() -> t.Check:
    var errors = vec.Vec[lexer.LexError].create()
    var tokens = lexer.lex(SRC_HEREDOC, ref_of(errors))

    t.expect(token_count(ref_of(tokens), lexer.TOK_CSTRING) == 1, "expected 1 cstring")?

    errors.release()
    tokens.release()
    return t.ok()


@[test]
function test_floats() -> t.Check:
    var errors = vec.Vec[lexer.LexError].create()
    var tokens = lexer.lex(SRC_FLOATS, ref_of(errors))

    t.expect_equal_int(token_kind_at(ref_of(tokens), 0), lexer.TOK_FLOAT)?
    t.expect_equal_int(token_kind_at(ref_of(tokens), 2), lexer.TOK_FLOAT)?
    t.expect_equal_int(token_kind_at(ref_of(tokens), 4), lexer.TOK_FLOAT)?

    errors.release()
    tokens.release()
    return t.ok()


@[test]
function test_bools() -> t.Check:
    var errors = vec.Vec[lexer.LexError].create()
    var tokens = lexer.lex(SRC_BOOLS, ref_of(errors))

    t.expect_equal_int(token_kind_at(ref_of(tokens), 0), lexer.TOK_KW_TRUE)?
    t.expect_equal_int(token_kind_at(ref_of(tokens), 2), lexer.TOK_KW_FALSE)?
    t.expect_equal_int(token_kind_at(ref_of(tokens), 4), lexer.TOK_KW_NULL)?

    errors.release()
    tokens.release()
    return t.ok()


@[test]
function test_indent_dedent() -> t.Check:
    var errors = vec.Vec[lexer.LexError].create()
    var tokens = lexer.lex(SRC_INDENT, ref_of(errors))
    var kinds = kinds_of(ref_of(tokens))

    t.expect(kinds.len() == 11, "token count")?
    t.expect_equal_int(kind_at(ref_of(kinds), 0), lexer.TOK_KW_STRUCT)?
    t.expect_equal_int(kind_at(ref_of(kinds), 2), lexer.TOK_COLON)?
    t.expect_equal_int(kind_at(ref_of(kinds), 3), lexer.TOK_NEWLINE)?
    t.expect_equal_int(kind_at(ref_of(kinds), 4), lexer.TOK_INDENT)?
    t.expect_equal_int(kind_at(ref_of(kinds), 9), lexer.TOK_DEDENT)?
    t.expect_equal_int(kind_at(ref_of(kinds), 10), lexer.TOK_EOF)?

    kinds.release()
    errors.release()
    tokens.release()
    return t.ok()


@[test]
function test_adjacent_strings() -> t.Check:
    var errors = vec.Vec[lexer.LexError].create()
    var tokens = lexer.lex(SRC_ADJACENT, ref_of(errors))

    t.expect(token_count(ref_of(tokens), lexer.TOK_STRING) == 1, "adjacent strings merge to one")?

    errors.release()
    tokens.release()
    return t.ok()


@[test]
function test_numeric_suffix() -> t.Check:
    var errors = vec.Vec[lexer.LexError].create()
    var tokens = lexer.lex(SRC_SUFFIX, ref_of(errors))

    t.expect_equal_int(token_kind_at(ref_of(tokens), 0), lexer.TOK_INTEGER)?
    t.expect_equal_int(token_kind_at(ref_of(tokens), 2), lexer.TOK_INTEGER)?

    errors.release()
    tokens.release()
    return t.ok()


@[test]
function test_continuation() -> t.Check:
    var errors = vec.Vec[lexer.LexError].create()
    var tokens = lexer.lex(SRC_CONTINUATION, ref_of(errors))

    t.expect_equal_int(token_kind_at(ref_of(tokens), 4), lexer.TOK_PLUS)?
    t.expect(token_count(ref_of(tokens), lexer.TOK_NEWLINE) == 1, "continuation suppresses newline")?

    errors.release()
    tokens.release()
    return t.ok()
