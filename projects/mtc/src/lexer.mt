import std.str as text
import std.vec as vec

const CH_NEWLINE: ubyte = '\n'
const CH_CR: ubyte = '\r'
const CH_SPACE: ubyte = ' '
const CH_TAB: ubyte = '\t'
const CH_HASH: ubyte = '#'
const CH_QUOTE: ubyte = '"'
const CH_SQUOTE: ubyte = '\''
const CH_BACKSLASH: ubyte = '\\'
const CH_ZERO: ubyte = '0'
const CH_C: ubyte = 'c'
const CH_F: ubyte = 'f'
const CH_LESS: ubyte = '<'
const CH_MORE: ubyte = '>'
const CH_MINUS: ubyte = '-'
const CH_DOT: ubyte = '.'
const CH_EQ: ubyte = '='
const CH_PLUS: ubyte = '+'
const CH_STAR: ubyte = '*'
const CH_SLASH: ubyte = '/'
const CH_PERCENT: ubyte = '%'
const CH_AMP: ubyte = '&'
const CH_PIPE: ubyte = '|'
const CH_CARET: ubyte = '^'
const CH_BANG: ubyte = '!'
const CH_LPAREN: ubyte = '('
const CH_RPAREN: ubyte = ')'
const CH_LBRACKET: ubyte = '['
const CH_RBRACKET: ubyte = ']'
const CH_COLON: ubyte = ':'
const CH_COMMA: ubyte = ','
const CH_AT: ubyte = '@'
const CH_QMARK: ubyte = '?'
const CH_E: ubyte = 'e'
const CH_E_UPPER: ubyte = 'E'
const CH_TILDE: ubyte = '~'
const CH_X_UPPER: ubyte = 'X'
const CH_X: ubyte = 'x'
const CH_B_UPPER: ubyte = 'B'
const CH_B: ubyte = 'b'

function is_alpha(b: ubyte) -> bool:
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or b == '_'

function is_digit(b: ubyte) -> bool:
    return b >= '0' and b <= '9'

function is_alphanumeric(b: ubyte) -> bool:
    return is_alpha(b) or is_digit(b)

function is_hex_digit(b: ubyte) -> bool:
    return is_digit(b) or (b >= 'A' and b <= 'F') or (b >= 'a' and b <= 'f')

function is_binary_digit(b: ubyte) -> bool:
    return b == '0' or b == '1'

function is_numeric_part(b: ubyte) -> bool:
    return is_digit(b) or b == '_'

# ── token kind constants ────────────────────────────────────────────────

public const TOK_EOF: int = 0
public const TOK_IDENTIFIER: int = 1
public const TOK_INTEGER: int = 2
public const TOK_FLOAT: int = 3
public const TOK_STRING: int = 4
public const TOK_CSTRING: int = 5
public const TOK_CHAR_LITERAL: int = 6
public const TOK_FSTRING: int = 7

public const TOK_INDENT: int = 10
public const TOK_DEDENT: int = 11
public const TOK_NEWLINE: int = 12

public const TOK_KW_TRUE: int = 20
public const TOK_KW_FALSE: int = 21
public const TOK_KW_NULL: int = 22

public const TOK_KW_ALIGN_OF: int = 30
public const TOK_KW_AND: int = 31
public const TOK_KW_AS: int = 32
public const TOK_KW_ASYNC: int = 33
public const TOK_KW_ATTRIBUTE: int = 34
public const TOK_KW_ATTRIBUTE_ARG: int = 35
public const TOK_KW_ATTRIBUTE_OF: int = 36
public const TOK_KW_ATTRIBUTES_OF: int = 37
public const TOK_KW_AWAIT: int = 38
public const TOK_KW_BREAK: int = 39
public const TOK_KW_CALLABLE_OF: int = 40
public const TOK_KW_COMPILER_FLAG: int = 41
public const TOK_KW_CONST: int = 42
public const TOK_KW_CONSUMING: int = 43
public const TOK_KW_CONTINUE: int = 44
public const TOK_KW_DEFER: int = 45
public const TOK_KW_DETACH: int = 46
public const TOK_KW_DYN: int = 47
public const TOK_KW_EDITABLE: int = 48
public const TOK_KW_ELSE: int = 49
public const TOK_KW_EMIT: int = 50
public const TOK_KW_ENUM: int = 51
public const TOK_KW_EVENT: int = 52
public const TOK_KW_EXTENDING: int = 53
public const TOK_KW_EXTERNAL: int = 54
public const TOK_KW_FIELD_OF: int = 55
public const TOK_KW_FIELDS_OF: int = 56
public const TOK_KW_FLAGS: int = 57
public const TOK_KW_FN: int = 58
public const TOK_KW_FOR: int = 59
public const TOK_KW_FOREIGN: int = 60
public const TOK_KW_FUNCTION: int = 61
public const TOK_KW_GATHER: int = 62
public const TOK_KW_HAS_ATTRIBUTE: int = 63
public const TOK_KW_IF: int = 64
public const TOK_KW_IMPLEMENTS: int = 65
public const TOK_KW_IMPORT: int = 66
public const TOK_KW_IN: int = 67
public const TOK_KW_INLINE: int = 68
public const TOK_KW_INOUT: int = 69
public const TOK_KW_INTERFACE: int = 70
public const TOK_KW_IS: int = 71
public const TOK_KW_LET: int = 72
public const TOK_KW_LINK: int = 73
public const TOK_KW_MATCH: int = 74
public const TOK_KW_MEMBERS_OF: int = 75
public const TOK_KW_MODULE: int = 76
public const TOK_KW_NOT: int = 77
public const TOK_KW_OFFSET_OF: int = 78
public const TOK_KW_OPAQUE: int = 79
public const TOK_KW_OR: int = 80
public const TOK_KW_OUT: int = 81
public const TOK_KW_PARALLEL: int = 82
public const TOK_KW_PASS: int = 83
public const TOK_KW_PROC: int = 84
public const TOK_KW_PUBLIC: int = 85
public const TOK_KW_RETURN: int = 86
public const TOK_KW_SIZE_OF: int = 87
public const TOK_KW_STATIC: int = 88
public const TOK_KW_STATIC_ASSERT: int = 89
public const TOK_KW_STRUCT: int = 90
public const TOK_KW_TYPE: int = 91
public const TOK_KW_UNION: int = 92
public const TOK_KW_UNSAFE: int = 93
public const TOK_KW_VAR: int = 94
public const TOK_KW_VARIANT: int = 95
public const TOK_KW_WHEN: int = 96
public const TOK_KW_WHILE: int = 97
public const TOK_KW_INCLUDE: int = 98

public const TOK_LPAREN: int = 100
public const TOK_RPAREN: int = 101
public const TOK_LBRACKET: int = 102
public const TOK_RBRACKET: int = 103
public const TOK_COLON: int = 104
public const TOK_COMMA: int = 105
public const TOK_DOT: int = 106
public const TOK_AT: int = 107
public const TOK_ARROW: int = 108
public const TOK_QUESTION: int = 109
public const TOK_ELLIPSIS: int = 110

public const TOK_EQUAL: int = 120
public const TOK_PLUS_EQUAL: int = 121
public const TOK_MINUS_EQUAL: int = 122
public const TOK_STAR_EQUAL: int = 123
public const TOK_SLASH_EQUAL: int = 124
public const TOK_PERCENT_EQUAL: int = 125
public const TOK_AMP_EQUAL: int = 126
public const TOK_PIPE_EQUAL: int = 127
public const TOK_CARET_EQUAL: int = 128
public const TOK_SHIFT_LEFT_EQUAL: int = 129
public const TOK_SHIFT_RIGHT_EQUAL: int = 130

public const TOK_PLUS: int = 140
public const TOK_MINUS: int = 141
public const TOK_STAR: int = 142
public const TOK_SLASH: int = 143
public const TOK_PERCENT: int = 144
public const TOK_AMP: int = 145
public const TOK_PIPE: int = 146
public const TOK_CARET: int = 147
public const TOK_TILDE: int = 148
public const TOK_LESS: int = 149
public const TOK_GREATER: int = 150
public const TOK_EQUAL_EQUAL: int = 151
public const TOK_BANG_EQUAL: int = 152
public const TOK_LESS_EQUAL: int = 153
public const TOK_GREATER_EQUAL: int = 154
public const TOK_SHIFT_LEFT: int = 155
public const TOK_SHIFT_RIGHT: int = 156
public const TOK_DOT_DOT: int = 157

# ── data structures ──────────────────────────────────────────────────────

const INDENT_STEP: int = 4


public struct Token:
    kind: int
    lexeme: str
    line: int
    column: int
    start_offset: ptr_uint
    end_offset: ptr_uint


public struct LexError:
    message: str
    line: int
    column: int


# ── keyword lookup ───────────────────────────────────────────────────────

function lookup_keyword(text_val: str) -> int:
    if text_val.equal("align_of"):
        return TOK_KW_ALIGN_OF
    else if text_val.equal("and"):
        return TOK_KW_AND
    else if text_val.equal("as"):
        return TOK_KW_AS
    else if text_val.equal("async"):
        return TOK_KW_ASYNC
    else if text_val.equal("attribute"):
        return TOK_KW_ATTRIBUTE
    else if text_val.equal("attribute_arg"):
        return TOK_KW_ATTRIBUTE_ARG
    else if text_val.equal("attribute_of"):
        return TOK_KW_ATTRIBUTE_OF
    else if text_val.equal("attributes_of"):
        return TOK_KW_ATTRIBUTES_OF
    else if text_val.equal("await"):
        return TOK_KW_AWAIT
    else if text_val.equal("break"):
        return TOK_KW_BREAK
    else if text_val.equal("callable_of"):
        return TOK_KW_CALLABLE_OF
    else if text_val.equal("compiler_flag"):
        return TOK_KW_COMPILER_FLAG
    else if text_val.equal("const"):
        return TOK_KW_CONST
    else if text_val.equal("consuming"):
        return TOK_KW_CONSUMING
    else if text_val.equal("continue"):
        return TOK_KW_CONTINUE
    else if text_val.equal("defer"):
        return TOK_KW_DEFER
    else if text_val.equal("detach"):
        return TOK_KW_DETACH
    else if text_val.equal("dyn"):
        return TOK_KW_DYN
    else if text_val.equal("editable"):
        return TOK_KW_EDITABLE
    else if text_val.equal("else"):
        return TOK_KW_ELSE
    else if text_val.equal("emit"):
        return TOK_KW_EMIT
    else if text_val.equal("enum"):
        return TOK_KW_ENUM
    else if text_val.equal("event"):
        return TOK_KW_EVENT
    else if text_val.equal("extending"):
        return TOK_KW_EXTENDING
    else if text_val.equal("external"):
        return TOK_KW_EXTERNAL
    else if text_val.equal("false"):
        return TOK_KW_FALSE
    else if text_val.equal("field_of"):
        return TOK_KW_FIELD_OF
    else if text_val.equal("fields_of"):
        return TOK_KW_FIELDS_OF
    else if text_val.equal("flags"):
        return TOK_KW_FLAGS
    else if text_val.equal("fn"):
        return TOK_KW_FN
    else if text_val.equal("for"):
        return TOK_KW_FOR
    else if text_val.equal("foreign"):
        return TOK_KW_FOREIGN
    else if text_val.equal("function"):
        return TOK_KW_FUNCTION
    else if text_val.equal("gather"):
        return TOK_KW_GATHER
    else if text_val.equal("has_attribute"):
        return TOK_KW_HAS_ATTRIBUTE
    else if text_val.equal("if"):
        return TOK_KW_IF
    else if text_val.equal("implements"):
        return TOK_KW_IMPLEMENTS
    else if text_val.equal("import"):
        return TOK_KW_IMPORT
    else if text_val.equal("in"):
        return TOK_KW_IN
    else if text_val.equal("include"):
        return TOK_KW_INCLUDE
    else if text_val.equal("inline"):
        return TOK_KW_INLINE
    else if text_val.equal("inout"):
        return TOK_KW_INOUT
    else if text_val.equal("interface"):
        return TOK_KW_INTERFACE
    else if text_val.equal("is"):
        return TOK_KW_IS
    else if text_val.equal("let"):
        return TOK_KW_LET
    else if text_val.equal("link"):
        return TOK_KW_LINK
    else if text_val.equal("match"):
        return TOK_KW_MATCH
    else if text_val.equal("members_of"):
        return TOK_KW_MEMBERS_OF
    else if text_val.equal("module"):
        return TOK_KW_MODULE
    else if text_val.equal("not"):
        return TOK_KW_NOT
    else if text_val.equal("null"):
        return TOK_KW_NULL
    else if text_val.equal("offset_of"):
        return TOK_KW_OFFSET_OF
    else if text_val.equal("opaque"):
        return TOK_KW_OPAQUE
    else if text_val.equal("or"):
        return TOK_KW_OR
    else if text_val.equal("out"):
        return TOK_KW_OUT
    else if text_val.equal("parallel"):
        return TOK_KW_PARALLEL
    else if text_val.equal("pass"):
        return TOK_KW_PASS
    else if text_val.equal("proc"):
        return TOK_KW_PROC
    else if text_val.equal("public"):
        return TOK_KW_PUBLIC
    else if text_val.equal("return"):
        return TOK_KW_RETURN
    else if text_val.equal("size_of"):
        return TOK_KW_SIZE_OF
    else if text_val.equal("static"):
        return TOK_KW_STATIC
    else if text_val.equal("static_assert"):
        return TOK_KW_STATIC_ASSERT
    else if text_val.equal("struct"):
        return TOK_KW_STRUCT
    else if text_val.equal("true"):
        return TOK_KW_TRUE
    else if text_val.equal("type"):
        return TOK_KW_TYPE
    else if text_val.equal("union"):
        return TOK_KW_UNION
    else if text_val.equal("unsafe"):
        return TOK_KW_UNSAFE
    else if text_val.equal("var"):
        return TOK_KW_VAR
    else if text_val.equal("variant"):
        return TOK_KW_VARIANT
    else if text_val.equal("when"):
        return TOK_KW_WHEN
    else if text_val.equal("while"):
        return TOK_KW_WHILE
    return TOK_IDENTIFIER


public function kind_name(kind: int) -> str:
    if kind == TOK_EOF:
        return "eof"
    if kind == TOK_IDENTIFIER:
        return "identifier"
    if kind == TOK_INTEGER:
        return "integer"
    if kind == TOK_FLOAT:
        return "float"
    if kind == TOK_STRING:
        return "string"
    if kind == TOK_CSTRING:
        return "cstring"
    if kind == TOK_CHAR_LITERAL:
        return "char_literal"
    if kind == TOK_FSTRING:
        return "fstring"
    if kind == TOK_INDENT:
        return "indent"
    if kind == TOK_DEDENT:
        return "dedent"
    if kind == TOK_NEWLINE:
        return "newline"
    if kind == TOK_KW_TRUE:
        return "true"
    if kind == TOK_KW_FALSE:
        return "false"
    if kind == TOK_KW_NULL:
        return "null"
    if kind == TOK_KW_ALIGN_OF:
        return "align_of"
    if kind == TOK_KW_AND:
        return "and"
    if kind == TOK_KW_AS:
        return "as"
    if kind == TOK_KW_ASYNC:
        return "async"
    if kind == TOK_KW_ATTRIBUTE:
        return "attribute"
    if kind == TOK_KW_ATTRIBUTE_ARG:
        return "attribute_arg"
    if kind == TOK_KW_ATTRIBUTE_OF:
        return "attribute_of"
    if kind == TOK_KW_ATTRIBUTES_OF:
        return "attributes_of"
    if kind == TOK_KW_AWAIT:
        return "await"
    if kind == TOK_KW_BREAK:
        return "break"
    if kind == TOK_KW_CALLABLE_OF:
        return "callable_of"
    if kind == TOK_KW_COMPILER_FLAG:
        return "compiler_flag"
    if kind == TOK_KW_CONST:
        return "const"
    if kind == TOK_KW_CONSUMING:
        return "consuming"
    if kind == TOK_KW_CONTINUE:
        return "continue"
    if kind == TOK_KW_DEFER:
        return "defer"
    if kind == TOK_KW_DETACH:
        return "detach"
    if kind == TOK_KW_DYN:
        return "dyn"
    if kind == TOK_KW_EDITABLE:
        return "editable"
    if kind == TOK_KW_ELSE:
        return "else"
    if kind == TOK_KW_EMIT:
        return "emit"
    if kind == TOK_KW_ENUM:
        return "enum"
    if kind == TOK_KW_EVENT:
        return "event"
    if kind == TOK_KW_EXTENDING:
        return "extending"
    if kind == TOK_KW_EXTERNAL:
        return "external"
    if kind == TOK_KW_FIELD_OF:
        return "field_of"
    if kind == TOK_KW_FIELDS_OF:
        return "fields_of"
    if kind == TOK_KW_FLAGS:
        return "flags"
    if kind == TOK_KW_FN:
        return "fn"
    if kind == TOK_KW_FOR:
        return "for"
    if kind == TOK_KW_FOREIGN:
        return "foreign"
    if kind == TOK_KW_FUNCTION:
        return "function"
    if kind == TOK_KW_GATHER:
        return "gather"
    if kind == TOK_KW_HAS_ATTRIBUTE:
        return "has_attribute"
    if kind == TOK_KW_IF:
        return "if"
    if kind == TOK_KW_IMPLEMENTS:
        return "implements"
    if kind == TOK_KW_IMPORT:
        return "import"
    if kind == TOK_KW_IN:
        return "in"
    if kind == TOK_KW_INCLUDE:
        return "include"
    if kind == TOK_KW_INLINE:
        return "inline"
    if kind == TOK_KW_INOUT:
        return "inout"
    if kind == TOK_KW_INTERFACE:
        return "interface"
    if kind == TOK_KW_IS:
        return "is"
    if kind == TOK_KW_LET:
        return "let"
    if kind == TOK_KW_LINK:
        return "link"
    if kind == TOK_KW_MATCH:
        return "match"
    if kind == TOK_KW_MEMBERS_OF:
        return "members_of"
    if kind == TOK_KW_MODULE:
        return "module"
    if kind == TOK_KW_NOT:
        return "not"
    if kind == TOK_KW_OFFSET_OF:
        return "offset_of"
    if kind == TOK_KW_OPAQUE:
        return "opaque"
    if kind == TOK_KW_OR:
        return "or"
    if kind == TOK_KW_OUT:
        return "out"
    if kind == TOK_KW_PARALLEL:
        return "parallel"
    if kind == TOK_KW_PASS:
        return "pass"
    if kind == TOK_KW_PROC:
        return "proc"
    if kind == TOK_KW_PUBLIC:
        return "public"
    if kind == TOK_KW_RETURN:
        return "return"
    if kind == TOK_KW_SIZE_OF:
        return "size_of"
    if kind == TOK_KW_STATIC:
        return "static"
    if kind == TOK_KW_STATIC_ASSERT:
        return "static_assert"
    if kind == TOK_KW_STRUCT:
        return "struct"
    if kind == TOK_KW_TYPE:
        return "type"
    if kind == TOK_KW_UNION:
        return "union"
    if kind == TOK_KW_UNSAFE:
        return "unsafe"
    if kind == TOK_KW_VAR:
        return "var"
    if kind == TOK_KW_VARIANT:
        return "variant"
    if kind == TOK_KW_WHEN:
        return "when"
    if kind == TOK_KW_WHILE:
        return "while"
    if kind == TOK_LPAREN:
        return "lparen"
    if kind == TOK_RPAREN:
        return "rparen"
    if kind == TOK_LBRACKET:
        return "lbracket"
    if kind == TOK_RBRACKET:
        return "rbracket"
    if kind == TOK_COLON:
        return "colon"
    if kind == TOK_COMMA:
        return "comma"
    if kind == TOK_DOT:
        return "dot"
    if kind == TOK_AT:
        return "at"
    if kind == TOK_ARROW:
        return "arrow"
    if kind == TOK_QUESTION:
        return "question"
    if kind == TOK_ELLIPSIS:
        return "ellipsis"
    if kind == TOK_EQUAL:
        return "equal"
    if kind == TOK_PLUS_EQUAL:
        return "plus_equal"
    if kind == TOK_MINUS_EQUAL:
        return "minus_equal"
    if kind == TOK_STAR_EQUAL:
        return "star_equal"
    if kind == TOK_SLASH_EQUAL:
        return "slash_equal"
    if kind == TOK_PERCENT_EQUAL:
        return "percent_equal"
    if kind == TOK_AMP_EQUAL:
        return "amp_equal"
    if kind == TOK_PIPE_EQUAL:
        return "pipe_equal"
    if kind == TOK_CARET_EQUAL:
        return "caret_equal"
    if kind == TOK_SHIFT_LEFT_EQUAL:
        return "shift_left_equal"
    if kind == TOK_SHIFT_RIGHT_EQUAL:
        return "shift_right_equal"
    if kind == TOK_PLUS:
        return "plus"
    if kind == TOK_MINUS:
        return "minus"
    if kind == TOK_STAR:
        return "star"
    if kind == TOK_SLASH:
        return "slash"
    if kind == TOK_PERCENT:
        return "percent"
    if kind == TOK_AMP:
        return "amp"
    if kind == TOK_PIPE:
        return "pipe"
    if kind == TOK_CARET:
        return "caret"
    if kind == TOK_TILDE:
        return "tilde"
    if kind == TOK_LESS:
        return "less"
    if kind == TOK_GREATER:
        return "greater"
    if kind == TOK_EQUAL_EQUAL:
        return "equal_equal"
    if kind == TOK_BANG_EQUAL:
        return "bang_equal"
    if kind == TOK_LESS_EQUAL:
        return "less_equal"
    if kind == TOK_GREATER_EQUAL:
        return "greater_equal"
    if kind == TOK_SHIFT_LEFT:
        return "shift_left"
    if kind == TOK_SHIFT_RIGHT:
        return "shift_right"
    if kind == TOK_DOT_DOT:
        return "dot_dot"
    return "unknown"


public function op_lexeme(kind: int) -> str:
    if kind == TOK_PLUS:
        return "+"
    if kind == TOK_MINUS:
        return "-"
    if kind == TOK_STAR:
        return "*"
    if kind == TOK_SLASH:
        return "/"
    if kind == TOK_PERCENT:
        return "%"
    if kind == TOK_DOT_DOT:
        return ".."
    if kind == TOK_PIPE:
        return "|"
    if kind == TOK_CARET:
        return "^"
    if kind == TOK_AMP:
        return "&"
    if kind == TOK_SHIFT_LEFT:
        return "<<"
    if kind == TOK_SHIFT_RIGHT:
        return ">>"
    if kind == TOK_EQUAL_EQUAL:
        return "=="
    if kind == TOK_BANG_EQUAL:
        return "!="
    if kind == TOK_LESS:
        return "<"
    if kind == TOK_GREATER:
        return ">"
    if kind == TOK_LESS_EQUAL:
        return "<="
    if kind == TOK_GREATER_EQUAL:
        return ">="
    if kind == TOK_KW_AND:
        return "and"
    if kind == TOK_KW_OR:
        return "or"
    if kind == TOK_KW_NOT:
        return "not"
    if kind == TOK_TILDE:
        return "~"
    if kind == TOK_EQUAL:
        return "="
    if kind == TOK_PLUS_EQUAL:
        return "+="
    if kind == TOK_MINUS_EQUAL:
        return "-="
    if kind == TOK_STAR_EQUAL:
        return "*="
    if kind == TOK_SLASH_EQUAL:
        return "/="
    if kind == TOK_PERCENT_EQUAL:
        return "%="
    if kind == TOK_AMP_EQUAL:
        return "&="
    if kind == TOK_PIPE_EQUAL:
        return "|="
    if kind == TOK_CARET_EQUAL:
        return "^="
    if kind == TOK_SHIFT_LEFT_EQUAL:
        return "<<="
    if kind == TOK_SHIFT_RIGHT_EQUAL:
        return ">>="
    return "unknown"


# ── token helpers ─────────────────────────────────────────────────────────

function emit_token(tokens: ref[vec.Vec[Token]], kind: int, lexeme: str,
                    line_num: int, col: int, start_off: ptr_uint,
                    end_off: ptr_uint) -> void:
    tokens.push(Token(
        kind = kind,
        lexeme = lexeme,
        line = line_num,
        column = col,
        start_offset = start_off,
        end_offset = end_off
    ))


function emit_error(errors: ref[vec.Vec[LexError]], msg: str,
                    line_num: int, col: int) -> void:
    errors.push(LexError(message = msg, line = line_num, column = col))


# ── source helpers ─────────────────────────────────────────────────────────

function find_line_end(source: str, start_pos: ptr_uint) -> ptr_uint:
    var pos = start_pos
    while pos < source.len:
        if source.byte_at(pos) == CH_NEWLINE:
            return pos
        pos += 1
    return source.len


function count_leading_spaces(line_val: str) -> ptr_uint:
    var i: ptr_uint = 0
    while i < line_val.len and line_val.byte_at(i) == CH_SPACE:
        i += 1
    return i


function is_blank_or_comment(line_val: str) -> bool:
    var i: ptr_uint = 0
    while i < line_val.len:
        let b = line_val.byte_at(i)
        if b == CH_SPACE or b == CH_TAB:
            i += 1
            continue
        return b == CH_HASH
    return true


# ── heredoc ───────────────────────────────────────────────────────────────

struct HdResult:
    lexeme: str
    start_off: ptr_uint
    end_off: ptr_uint
    term_line: int
    term_off: ptr_uint
    term_len: ptr_uint


function is_heredoc_start(line_val: str, start_pos: ptr_uint,
                          is_cstr: bool, is_fmt: bool) -> bool:
    let required = if is_cstr or is_fmt: ptr_uint<-(4) else: ptr_uint<-(3)
    if start_pos + required > line_val.len:
        return false
    var offset = start_pos
    if is_cstr:
        if line_val.byte_at(offset) != CH_C:
            return false
        offset = offset + 1
    else if is_fmt:
        if line_val.byte_at(offset) != CH_F:
            return false
        offset = offset + 1
    if line_val.byte_at(offset) != CH_LESS:
        return false
    if line_val.byte_at(offset + 1) != CH_LESS:
        return false
    if line_val.byte_at(offset + 2) != CH_MINUS:
        return false
    offset = offset + 3
    if offset >= line_val.len:
        return false
    return is_alpha(line_val.byte_at(offset))


function read_ref_u(p: ref[ptr_uint]) -> ptr_uint:
    return unsafe: read(ptr[ptr_uint]<-p)


function write_ref_u(p: ref[ptr_uint], val: ptr_uint) -> void:
    unsafe: read(ptr[ptr_uint]<-p) = val


function read_ref_i(p: ref[int]) -> int:
    return unsafe: read(ptr[int]<-p)


function write_ref_i(p: ref[int], val: int) -> void:
    unsafe: read(ptr[int]<-p) = val


function find_heredoc_tag(line_val: str, start_pos: ptr_uint) -> str:
    var tag_start = start_pos
    if line_val.byte_at(tag_start) == CH_C or line_val.byte_at(tag_start) == CH_F:
        tag_start = tag_start + 1
    tag_start = tag_start + 3
    var tag_end = tag_start
    while tag_end < line_val.len and is_alphanumeric(line_val.byte_at(tag_end)):
        tag_end = tag_end + 1
    return line_val.slice(tag_start, tag_end - tag_start)


function emit_heredoc(tokens: ref[vec.Vec[Token]], kind: int, consumed: HdResult,
                     hd_line: int, hd_col: ptr_uint, group_depth: int) -> void:
    emit_token(tokens, kind, consumed.lexeme, hd_line, int<-hd_col + 1,
        consumed.start_off, consumed.end_off)
    if group_depth == 0:
        let nl_start = consumed.term_off + consumed.term_len
        emit_token(tokens, TOK_NEWLINE, "\n", consumed.term_line,
            int<-consumed.term_len + 1, nl_start, nl_start + 1)


function lex_heredoc(source: str, pos: ref[ptr_uint], line_num: ref[int],
                     first_line: str, start_pos: ptr_uint) -> HdResult:
    let tag = find_heredoc_tag(first_line, start_pos)
    let start_offset = read_ref_u(pos) + start_pos
    var scan_pos = read_ref_u(pos) + first_line.len + 1
    var scan_line = read_ref_i(line_num) + 1

    while scan_pos < source.len:
        let line_end = find_line_end(source, scan_pos)
        var line_len = line_end - scan_pos
        if line_len > 0 and source.byte_at(line_end - 1) == CH_CR:
            line_len = line_len - 1
        let line_val = source.slice(scan_pos, line_len)

        let bare = trim_blank(line_val)
        if bare.equal(tag):
            let end_offset = scan_pos + line_len
            let lexeme = source.slice(start_offset, end_offset - start_offset)
            write_ref_u(pos, line_end + 1)
            write_ref_i(line_num, scan_line + 1)
            return HdResult(lexeme = lexeme, start_off = start_offset,
                end_off = end_offset, term_line = scan_line,
                term_off = scan_pos, term_len = line_len)

        scan_pos = line_end + 1
        scan_line = scan_line + 1

    write_ref_u(pos, scan_pos)
    write_ref_i(line_num, scan_line)
    return HdResult(lexeme = source.slice(start_offset, scan_pos - start_offset),
        start_off = start_offset, end_off = scan_pos,
        term_line = scan_line, term_off = scan_pos, term_len = 0)


function trim_blank(s: str) -> str:
    var start: ptr_uint = 0
    while start < s.len:
        let b = s.byte_at(start)
        if b == CH_SPACE or b == CH_TAB or b == CH_CR:
            start = start + 1
        else:
            break
    var end_i = s.len
    while end_i > start:
        let b = s.byte_at(end_i - 1)
        if b == CH_SPACE or b == CH_TAB or b == CH_CR:
            end_i = end_i - 1
        else:
            break
    return s.slice(start, end_i - start)


# ── top-level resync ────────────────────────────────────────────────────────

function is_top_level_decl(line_str: str) -> bool:
    var idx: ptr_uint = 0
    while idx < line_str.len and line_str.byte_at(idx) == CH_SPACE:
        idx = idx + 1
    if idx >= line_str.len:
        return false
    let first = first_word(line_str, ref_of(idx))
    if is_top_kw(first):
        return true
    if first.equal("async"):
        var rest_idx = skip_spaces(line_str, ref_of(idx))
        let second = first_word(line_str, ref_of(rest_idx))
        return second.equal("function")
    if first.equal("public"):
        var rest_idx = skip_spaces(line_str, ref_of(idx))
        let second = first_word(line_str, ref_of(rest_idx))
        return is_top_kw(second)
    if first.equal("foreign") or first.equal("external"):
        var rest_idx = skip_spaces(line_str, ref_of(idx))
        let second = first_word(line_str, ref_of(rest_idx))
        return second.equal("function")
    return false


function is_top_kw(text_val: str) -> bool:
    if text_val.equal("attribute"):
        return true
    if text_val.equal("const"):
        return true
    if text_val.equal("enum"):
        return true
    if text_val.equal("external"):
        return true
    if text_val.equal("flags"):
        return true
    if text_val.equal("foreign"):
        return true
    if text_val.equal("function"):
        return true
    if text_val.equal("include"):
        return true
    if text_val.equal("import"):
        return true
    if text_val.equal("interface"):
        return true
    if text_val.equal("link"):
        return true
    if text_val.equal("opaque"):
        return true
    if text_val.equal("public"):
        return true
    if text_val.equal("static_assert"):
        return true
    if text_val.equal("struct"):
        return true
    if text_val.equal("type"):
        return true
    if text_val.equal("union"):
        return true
    if text_val.equal("var"):
        return true
    if text_val.equal("variant"):
        return true
    if text_val.equal("extending"):
        return true
    if text_val.equal("event"):
        return true
    return false


function first_word(line_str: str, idx: ref[ptr_uint]) -> str:
    let start = read_ref_u(idx)
    var end_idx = start
    while end_idx < line_str.len and is_alphanumeric(line_str.byte_at(end_idx)):
        end_idx = end_idx + 1
    unsafe: read(ptr[ptr_uint]<-idx) = end_idx
    return line_str.slice(start, end_idx - start)


function skip_spaces(line_str: str, idx: ref[ptr_uint]) -> ptr_uint:
    var i = read_ref_u(idx)
    while i < line_str.len and line_str.byte_at(i) == CH_SPACE:
        i = i + 1
    return i


# ── adjacent string merging ────────────────────────────────────────────────

function try_merge_adjacent(source: str, pos: ref[ptr_uint],
                            line_num: ref[int],
                            tokens: ref[vec.Vec[Token]],
                            indent_amt: ptr_uint,
                            current_line_end: ptr_uint,
                            group_depth: int) -> int:
    if tokens.len() == 0:
        return 0
    let last_tok = tokens.last() else:
        return 0
    let last_kind = unsafe: read(ptr[Token]<-last_tok).kind
    if last_kind != TOK_STRING and last_kind != TOK_CSTRING:
        return 0

    var merged: int = 0
    var next_pos = current_line_end + 1
    var last_nl_start: ptr_uint = 0
    var last_col_len: ptr_uint = 0

    while true:
        while next_pos < source.len and source.byte_at(next_pos) == CH_CR:
            next_pos = next_pos + 1
        if next_pos >= source.len:
            break

        let nle = find_line_end(source, next_pos)
        var nll = nle - next_pos
        if nll > 0 and source.byte_at(nle - 1) == CH_CR:
            nll = nll - 1
        if nll == 0:
            break

        let nls = source.slice(next_pos, nll)
        if is_blank_or_comment(nls):
            break

        let next_indent = count_leading_spaces(nls)
        if next_indent <= indent_amt:
            break

        let first_ch = next_indent
        if first_ch >= nll:
            break

        let nb = nls.byte_at(first_ch)
        var str_start: ptr_uint = first_ch

        if nb == CH_C and first_ch + 1 < nll and nls.byte_at(first_ch + 1) == CH_QUOTE:
            if last_kind != TOK_CSTRING:
                break
            str_start = str_start + 1
        else if nb == CH_QUOTE:
            if last_kind != TOK_STRING:
                break
        else:
            break

        let str_end = scan_plain_string(nls, str_start)
        if str_end <= str_start:
            break

        let new_end = next_pos + str_end + 1
        unsafe:
            let tok_ptr = ptr[Token]<-last_tok
            read(tok_ptr).lexeme = source.slice(read(tok_ptr).start_offset,
                new_end - read(tok_ptr).start_offset)
            read(tok_ptr).end_offset = new_end

        last_nl_start = next_pos + nll
        last_col_len = nll
        next_pos = nle + 1
        merged = merged + 1

    if merged == 0:
        return 0

    write_ref_u(pos, next_pos)
    let term_line = read_ref_i(line_num) + merged
    write_ref_i(line_num, term_line + 1)
    if group_depth == 0:
        emit_token(tokens, TOK_NEWLINE, "\n", term_line,
            int<-last_col_len + 1, last_nl_start, last_nl_start + 1)
    return merged


# ── main lex function ─────────────────────────────────────────────────────

public function lex(source: str, errors: ref[vec.Vec[LexError]]) -> vec.Vec[Token]:
    var tokens = vec.Vec[Token].create()
    var pos: ptr_uint = 0
    var line_num: int = 1
    var indent_stack = vec.Vec[int].create()
    indent_stack.push(0)
    var group_depth: int = 0
    var cont_pending: bool = false
    var heredoc_consumed: bool = false
    var adj_consumed: bool = false

    while pos < source.len:
        if pos < source.len and source.byte_at(pos) == CH_CR:
            pos = pos + 1
            continue

        let line_end = find_line_end(source, pos)
        var line_len = line_end - pos

        if line_len > 0 and source.byte_at(line_end - 1) == CH_CR:
            line_len = line_len - 1

        if line_len == 0:
            pos = line_end + 1
            line_num += 1
            continue

        let line_str = source.slice(pos, line_len)

        if is_blank_or_comment(line_str):
            pos = line_end + 1
            line_num += 1
            continue

        let indent_amt = count_leading_spaces(line_str)

        if indent_amt % ptr_uint<-(INDENT_STEP) != 0:
            emit_error(errors, "indentation must use multiples of 4 spaces", line_num, 1)

        if group_depth > 0 and indent_amt == 0:
            if is_top_level_decl(line_str):
                emit_error(errors, "unclosed grouping delimiter", line_num, 1)
                group_depth = 0

        if group_depth == 0 and not cont_pending:
            let spaces = int<-indent_amt
            let top_ptr = indent_stack.last() else:
                fatal("lexer: indent stack empty")
            let current = unsafe: read(ptr[int]<-top_ptr)
            if spaces == current:
                pass
            else if spaces > current:
                if spaces != current + INDENT_STEP:
                    emit_error(errors, "indentation may only increase by 4 spaces at a time", line_num, 1)
                indent_stack.push(spaces)
                emit_token(ref_of(tokens), TOK_INDENT, "", line_num, 1, pos, pos)
            else if spaces < current:
                while indent_stack.len() > 1:
                    let p = indent_stack.last() else:
                        fatal("lexer: indent stack empty")
                    if unsafe: read(ptr[int]<-p) > spaces:
                        indent_stack.pop()
                        emit_token(ref_of(tokens), TOK_DEDENT, "", line_num, 1, pos, pos)
                    else:
                        break
                let final_ptr = indent_stack.last() else:
                    fatal("lexer: indent stack empty")
                if unsafe: read(ptr[int]<-final_ptr) != spaces:
                    emit_error(errors, "indentation does not match any open block", line_num, 1)
        cont_pending = false

        var line_pos = indent_amt

        while line_pos < line_len:
            let b = line_str.byte_at(line_pos)

            if b == CH_SPACE:
                line_pos += 1
                continue

            if b == CH_HASH:
                break

            if b == CH_QUOTE:
                let end_pos = scan_plain_string(line_str, line_pos)
                if end_pos > line_pos:
                    let lexeme = line_str.slice(line_pos, end_pos + 1 - line_pos)
                    emit_token(ref_of(tokens), TOK_STRING, lexeme, line_num,
                        int<-line_pos + 1, pos + line_pos, pos + end_pos + 1)
                    line_pos = end_pos + 1
                else:
                    emit_error(errors, "unterminated string literal", line_num, int<-line_pos + 1)
                    line_pos = line_len
                continue

            if b == CH_C and line_pos + 1 < line_len and line_str.byte_at(line_pos + 1) == CH_QUOTE:
                let end_pos = scan_plain_string(line_str, line_pos + 1)
                if end_pos > line_pos + 1:
                    let lexeme = line_str.slice(line_pos, end_pos + 1 - line_pos)
                    emit_token(ref_of(tokens), TOK_CSTRING, lexeme, line_num,
                        int<-line_pos + 1, pos + line_pos, pos + end_pos + 1)
                    line_pos = end_pos + 1
                else:
                    emit_error(errors, "unterminated cstring literal", line_num, int<-line_pos + 1)
                    line_pos = line_len
                continue

            if b == CH_C and is_heredoc_start(line_str, line_pos, true, false):
                let hd_line = line_num
                let consumed = lex_heredoc(source, ref_of(pos), ref_of(line_num),
                    line_str, line_pos)
                emit_heredoc(ref_of(tokens), TOK_CSTRING, consumed, hd_line, line_pos, group_depth)
                heredoc_consumed = true
                break

            if b == CH_F and line_pos + 1 < line_len and line_str.byte_at(line_pos + 1) == CH_QUOTE:
                let end_pos = scan_plain_string(line_str, line_pos + 1)
                if end_pos > line_pos + 1:
                    let lexeme = line_str.slice(line_pos, end_pos + 1 - line_pos)
                    emit_token(ref_of(tokens), TOK_FSTRING, lexeme, line_num,
                        int<-line_pos + 1, pos + line_pos, pos + end_pos + 1)
                    line_pos = end_pos + 1
                else:
                    emit_error(errors, "unterminated format string literal", line_num, int<-line_pos + 1)
                    line_pos = line_len
                continue

            if b == CH_F and is_heredoc_start(line_str, line_pos, false, true):
                let hd_line = line_num
                let consumed = lex_heredoc(source, ref_of(pos), ref_of(line_num),
                    line_str, line_pos)
                emit_heredoc(ref_of(tokens), TOK_FSTRING, consumed, hd_line, line_pos, group_depth)
                heredoc_consumed = true
                break

            if is_heredoc_start(line_str, line_pos, false, false):
                let hd_line = line_num
                let consumed = lex_heredoc(source, ref_of(pos), ref_of(line_num),
                    line_str, line_pos)
                emit_heredoc(ref_of(tokens), TOK_STRING, consumed, hd_line, line_pos, group_depth)
                heredoc_consumed = true
                break

            if b == CH_SQUOTE:
                let start_pos = line_pos
                let ch_pos = start_pos + 1
                if ch_pos < line_len:
                    let ch_val = line_str.byte_at(ch_pos)
                    if ch_val == CH_BACKSLASH:
                        if ch_pos + 1 < line_len:
                            let esc_ch = line_str.byte_at(ch_pos + 1)
                            if esc_ch == CH_X_UPPER or esc_ch == CH_X:
                                if ch_pos + 4 < line_len and line_str.byte_at(ch_pos + 4) == CH_SQUOTE:
                                    let lexeme = line_str.slice(start_pos, 6)
                                    emit_token(ref_of(tokens), TOK_CHAR_LITERAL, lexeme, line_num,
                                        int<-start_pos + 1, pos + start_pos, pos + ch_pos + 5)
                                    line_pos = ch_pos + 5
                                    continue
                            let close_pos = ch_pos + 2
                            if close_pos < line_len and line_str.byte_at(close_pos) == CH_SQUOTE:
                                let lexeme = line_str.slice(start_pos, close_pos + 1 - start_pos)
                                emit_token(ref_of(tokens), TOK_CHAR_LITERAL, lexeme, line_num,
                                    int<-start_pos + 1, pos + start_pos, pos + close_pos + 1)
                                line_pos = close_pos + 1
                                continue
                    else:
                        let close_pos = ch_pos + 1
                        if close_pos < line_len and line_str.byte_at(close_pos) == CH_SQUOTE:
                            let lexeme = line_str.slice(start_pos, close_pos + 1 - start_pos)
                            emit_token(ref_of(tokens), TOK_CHAR_LITERAL, lexeme, line_num,
                                int<-start_pos + 1, pos + start_pos, pos + close_pos + 1)
                            line_pos = close_pos + 1
                            continue
                emit_error(errors, "unterminated character literal", line_num, int<-line_pos + 1)
                line_pos = line_pos + 1
                continue

            if is_alpha(b):
                let end_pos = scan_ident(line_str, line_pos)
                let lexeme = line_str.slice(line_pos, end_pos - line_pos)
                let kind = lookup_keyword(lexeme)
                emit_token(ref_of(tokens), kind, lexeme, line_num,
                    int<-line_pos + 1, pos + line_pos, pos + end_pos)
                line_pos = end_pos
                continue

            if is_digit(b):
                let base_end = scan_number(line_str, line_pos)
                let suffix_end = scan_number_suffix(line_str, line_pos, base_end)
                let lexeme = line_str.slice(line_pos, suffix_end - line_pos)
                let is_float = lexeme_is_float(lexeme)
                if is_float:
                    emit_token(ref_of(tokens), TOK_FLOAT, lexeme, line_num,
                        int<-line_pos + 1, pos + line_pos, pos + suffix_end)
                else:
                    emit_token(ref_of(tokens), TOK_INTEGER, lexeme, line_num,
                        int<-line_pos + 1, pos + line_pos, pos + suffix_end)
                line_pos = suffix_end
                continue

            line_pos = scan_op(line_str, line_pos, ref_of(tokens),
                              ref_of(group_depth), line_num, pos, errors)

        adj_consumed = try_merge_adjacent(source, ref_of(pos), ref_of(line_num),
            ref_of(tokens), indent_amt, line_end, group_depth) > 0

        if group_depth == 0 and not heredoc_consumed and not adj_consumed:
            let is_cont = is_continuation_op(ref_of(tokens))
            if is_cont:
                cont_pending = true
            else:
                emit_token(ref_of(tokens), TOK_NEWLINE, "\n", line_num, int<-line_len + 1,
                    pos + line_len, pos + line_len + 1)

        if adj_consumed:
            adj_consumed = false
        else if heredoc_consumed:
            heredoc_consumed = false
        else:
            pos = line_end + 1
            line_num += 1

    while indent_stack.len() > 1:
        indent_stack.pop()
        emit_token(ref_of(tokens), TOK_DEDENT, "", line_num - 1, 1, pos, pos)

    emit_token(ref_of(tokens), TOK_EOF, "", line_num, 1, pos, pos)
    indent_stack.release()
    return tokens


# ── identifier scanning ───────────────────────────────────────────────────

function scan_ident(line_val: str, start_pos: ptr_uint) -> ptr_uint:
    var pos = start_pos + 1
    while pos < line_val.len and is_alphanumeric(line_val.byte_at(pos)):
        pos += 1
    return pos


# ── number scanning ───────────────────────────────────────────────────────

function scan_number(line_val: str, start_pos: ptr_uint) -> ptr_uint:
    var pos = start_pos

    if line_val.byte_at(pos) == CH_ZERO:
        if pos + 1 < line_val.len:
            let nxt = line_val.byte_at(pos + 1)
            if nxt == CH_X_UPPER or nxt == CH_X:
                pos += 2
                while pos < line_val.len and (is_hex_digit(line_val.byte_at(pos)) or line_val.byte_at(pos) == '_'):
                    pos += 1
            else if nxt == CH_B_UPPER or nxt == CH_B:
                pos += 2
                while pos < line_val.len and (is_binary_digit(line_val.byte_at(pos)) or line_val.byte_at(pos) == '_'):
                    pos += 1

    if pos == start_pos:
        while pos < line_val.len and is_numeric_part(line_val.byte_at(pos)):
            pos += 1

    if pos < line_val.len and line_val.byte_at(pos) == CH_DOT:
        if pos + 1 < line_val.len and is_digit(line_val.byte_at(pos + 1)):
            pos += 1
            while pos < line_val.len and is_numeric_part(line_val.byte_at(pos)):
                pos += 1

    if pos < line_val.len:
        let eb = line_val.byte_at(pos)
        if eb == CH_E or eb == CH_E_UPPER:
            var look = pos + 1
            if look < line_val.len and (line_val.byte_at(look) == CH_PLUS or line_val.byte_at(look) == CH_MINUS):
                look += 1
            if look < line_val.len and is_digit(line_val.byte_at(look)):
                pos = look
                while pos < line_val.len and is_digit(line_val.byte_at(pos)):
                    pos += 1

    return pos


function scan_number_suffix(line_val: str, num_start: ptr_uint,
                            num_end: ptr_uint) -> ptr_uint:
    var pos = num_end
    if pos >= line_val.len:
        return pos

    let ch = line_val.byte_at(pos)
    if not is_alpha(ch):
        return pos

    var is_float_num = false
    var scan: ptr_uint = num_start
    while scan < num_end:
        let b = line_val.byte_at(scan)
        if b == CH_DOT or b == CH_E or b == CH_E_UPPER:
            is_float_num = true
            break
        scan += 1

    if is_float_num:
        if ch == 'f' or ch == 'd' or ch == 'F' or ch == 'D':
            if pos + 1 >= line_val.len or not is_alphanumeric(line_val.byte_at(pos + 1)):
                return pos + 1
        return pos

    if pos + 2 <= line_val.len:
        let s2 = line_val.slice(pos, 2)
        if (s2.equal("ub") or s2.equal("us") or s2.equal("ul") or s2.equal("iz")):
            if pos + 2 >= line_val.len or not is_alphanumeric(line_val.byte_at(pos + 2)):
                return pos + 2
    if ch == 'u' or ch == 'b' or ch == 's' or ch == 'i' or ch == 'l' or ch == 'z':
        if pos + 1 >= line_val.len or not is_alphanumeric(line_val.byte_at(pos + 1)):
            return pos + 1
    return pos


function lexeme_is_float(lexeme: str) -> bool:
    if lexeme.len >= 2 and lexeme.byte_at(0) == CH_ZERO:
        let second = lexeme.byte_at(1)
        if second == CH_X_UPPER or second == CH_X:
            return false
        if second == CH_B_UPPER or second == CH_B:
            return false
    var i: ptr_uint = 0
    while i < lexeme.len:
        let b = lexeme.byte_at(i)
        if b == CH_DOT or b == CH_E or b == CH_E_UPPER:
            return true
        i += 1
    return false


# ── string scanning ───────────────────────────────────────────────────────

function scan_plain_string(line_val: str, start_pos: ptr_uint) -> ptr_uint:
    var pos = start_pos + 1
    while pos < line_val.len:
        let b = line_val.byte_at(pos)
        if b == CH_QUOTE:
            return pos
        if b == CH_BACKSLASH and pos + 1 < line_val.len:
            pos += 2
            continue
        pos += 1
    return start_pos


# ── operator / delimiter scanning ─────────────────────────────────────────

function scan_op(line_val: str, start_pos: ptr_uint,
                 tokens: ref[vec.Vec[Token]],
                 group_depth: ref[int], line_num: int,
                 line_offset: ptr_uint,
                 errors: ref[vec.Vec[LexError]]) -> ptr_uint:
    let pos = start_pos
    let b0 = line_val.byte_at(pos)
    let b1 = if pos + 1 < line_val.len: line_val.byte_at(pos + 1) else: CH_ZERO
    let b2 = if pos + 2 < line_val.len: line_val.byte_at(pos + 2) else: CH_ZERO

    if b0 == CH_DOT and b1 == CH_DOT and b2 == CH_DOT:
        emit_token(tokens, TOK_ELLIPSIS, "...", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 3)
        return pos + 3

    if b0 == CH_LESS and b1 == CH_LESS and b2 == CH_EQ:
        emit_token(tokens, TOK_SHIFT_LEFT_EQUAL, "<<=", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 3)
        return pos + 3

    if b0 == CH_MORE and b1 == CH_MORE and b2 == CH_EQ:
        emit_token(tokens, TOK_SHIFT_RIGHT_EQUAL, ">>=", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 3)
        return pos + 3

    if b0 == CH_MINUS and b1 == CH_MORE:
        emit_token(tokens, TOK_ARROW, "->", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 2)
        return pos + 2
    if b0 == CH_DOT and b1 == CH_DOT:
        emit_token(tokens, TOK_DOT_DOT, "..", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 2)
        return pos + 2
    if b0 == CH_LESS and b1 == CH_LESS:
        emit_token(tokens, TOK_SHIFT_LEFT, "<<", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 2)
        return pos + 2
    if b0 == CH_MORE and b1 == CH_MORE:
        emit_token(tokens, TOK_SHIFT_RIGHT, ">>", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 2)
        return pos + 2

    if b0 == CH_PLUS and b1 == CH_EQ:
        emit_token(tokens, TOK_PLUS_EQUAL, "+=", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 2)
        return pos + 2
    if b0 == CH_MINUS and b1 == CH_EQ:
        emit_token(tokens, TOK_MINUS_EQUAL, "-=", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 2)
        return pos + 2
    if b0 == CH_STAR and b1 == CH_EQ:
        emit_token(tokens, TOK_STAR_EQUAL, "*=", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 2)
        return pos + 2
    if b0 == CH_SLASH and b1 == CH_EQ:
        emit_token(tokens, TOK_SLASH_EQUAL, "/=", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 2)
        return pos + 2
    if b0 == CH_PERCENT and b1 == CH_EQ:
        emit_token(tokens, TOK_PERCENT_EQUAL, "%=", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 2)
        return pos + 2
    if b0 == CH_AMP and b1 == CH_EQ:
        emit_token(tokens, TOK_AMP_EQUAL, "&=", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 2)
        return pos + 2
    if b0 == CH_PIPE and b1 == CH_EQ:
        emit_token(tokens, TOK_PIPE_EQUAL, "|=", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 2)
        return pos + 2
    if b0 == CH_CARET and b1 == CH_EQ:
        emit_token(tokens, TOK_CARET_EQUAL, "^=", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 2)
        return pos + 2
    if b0 == CH_EQ and b1 == CH_EQ:
        emit_token(tokens, TOK_EQUAL_EQUAL, "==", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 2)
        return pos + 2
    if b0 == CH_BANG and b1 == CH_EQ:
        emit_token(tokens, TOK_BANG_EQUAL, "!=", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 2)
        return pos + 2
    if b0 == CH_LESS and b1 == CH_EQ:
        emit_token(tokens, TOK_LESS_EQUAL, "<=", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 2)
        return pos + 2
    if b0 == CH_MORE and b1 == CH_EQ:
        emit_token(tokens, TOK_GREATER_EQUAL, ">=", line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 2)
        return pos + 2

    let kind = scan_single(b0, group_depth)
    if kind == TOK_EOF:
        emit_error(errors, "unexpected character", line_num, int<-pos + 1)
    else:
        emit_token(tokens, kind, line_val.slice(pos, 1), line_num, int<-pos + 1,
            line_offset + pos, line_offset + pos + 1)

    return pos + 1


function scan_single(b: ubyte, group_depth: ref[int]) -> int:
    if b == CH_LPAREN:
        unsafe: read(group_depth) = read(group_depth) + 1
        return TOK_LPAREN
    if b == CH_RPAREN:
        unsafe: read(group_depth) = read(group_depth) - 1
        return TOK_RPAREN
    if b == CH_LBRACKET:
        unsafe: read(group_depth) = read(group_depth) + 1
        return TOK_LBRACKET
    if b == CH_RBRACKET:
        unsafe: read(group_depth) = read(group_depth) - 1
        return TOK_RBRACKET
    if b == CH_COLON:
        return TOK_COLON
    if b == CH_COMMA:
        return TOK_COMMA
    if b == CH_DOT:
        return TOK_DOT
    if b == CH_AT:
        return TOK_AT
    if b == CH_QMARK:
        return TOK_QUESTION
    if b == CH_EQ:
        return TOK_EQUAL
    if b == CH_PLUS:
        return TOK_PLUS
    if b == CH_MINUS:
        return TOK_MINUS
    if b == CH_STAR:
        return TOK_STAR
    if b == CH_SLASH:
        return TOK_SLASH
    if b == CH_PERCENT:
        return TOK_PERCENT
    if b == CH_AMP:
        return TOK_AMP
    if b == CH_PIPE:
        return TOK_PIPE
    if b == CH_CARET:
        return TOK_CARET
    if b == CH_TILDE:
        return TOK_TILDE
    if b == CH_LESS:
        return TOK_LESS
    if b == CH_MORE:
        return TOK_GREATER
    return TOK_EOF


# ── line continuation ──────────────────────────────────────────────────────

function is_continuation_op(tokens: ref[vec.Vec[Token]]) -> bool:
    if tokens.len() == 0:
        return false
    let last_idx = tokens.len() - 1
    let t = tokens.get(last_idx) else:
        return false
    unsafe:
        let kind = read(ptr[Token]<-t).kind
        if kind == TOK_DOT_DOT:
            return true
        if kind == TOK_PLUS:
            return true
        if kind == TOK_MINUS:
            return true
        if kind == TOK_STAR:
            return true
        if kind == TOK_SLASH:
            return true
        if kind == TOK_PERCENT:
            return true
        if kind == TOK_PIPE:
            return true
        if kind == TOK_AMP:
            return true
        if kind == TOK_CARET:
            return true
        if kind == TOK_KW_OR:
            return true
        if kind == TOK_KW_AND:
            return true
        if kind == TOK_EQUAL_EQUAL:
            return true
        if kind == TOK_BANG_EQUAL:
            return true
        if kind == TOK_LESS:
            return true
        if kind == TOK_LESS_EQUAL:
            return true
        if kind == TOK_GREATER:
            return true
        if kind == TOK_GREATER_EQUAL:
            return true
        if kind == TOK_SHIFT_LEFT:
            return true
        if kind == TOK_SHIFT_RIGHT:
            return true
        return false
