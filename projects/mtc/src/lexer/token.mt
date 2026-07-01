import std.str
import std.vec


public enum TokenKind: ubyte
    eof = 0
    identifier = 1
    keyword = 2
    integer_literal = 3
    float_literal = 4
    char_literal = 5
    string_literal = 6
    cstring_literal = 7
    fstring_literal = 8
    symbol = 9
    indent = 10
    dedent = 11
    newline = 12
    comment = 13

public struct Token:
    kind: TokenKind
    lexeme: str
    line: ptr_uint
    column: ptr_uint
    start_offset: ptr_uint
    end_offset: ptr_uint


const KEYWORD_COUNT: ptr_uint = 57

const keywords_list: array[str, KEYWORD_COUNT] = array[str, KEYWORD_COUNT](
    "function", "struct", "enum", "union", "variant", "flags", "opaque",
    "if", "else", "while", "for", "match", "return", "let", "var", "const",
    "true", "false", "null",
    "and", "or", "not", "is", "in", "out", "inout",
    "import", "public", "external", "foreign", "extending", "interface", "attribute", "event",
    "static_assert", "defer", "unsafe", "pass", "break", "continue",
    "async", "await", "inline", "when", "emit",
    "parallel", "detach", "gather",
    "with", "proc",
    "as", "do", "module", "consuming", "compiler_flag", "include", "link",
)


public const INT_SUFFIX_COUNT: ptr_uint = 10

public const int_suffixes: array[str, INT_SUFFIX_COUNT] = array[str, INT_SUFFIX_COUNT](
    "ub", "us", "ul", "iz", "b", "s", "i", "u", "l", "z"
)


public struct ScanResult:
    lines_consumed: ptr_uint
    next_offset: ptr_uint


public function is_keyword(ident: str) -> bool:
    var index: ptr_uint = 0
    while index < KEYWORD_COUNT:
        if ident == keywords_list[index]:
            return true
        index += 1

    return false


public function push_token(
    tokens: ref[vec.Vec[Token]],
    kind: TokenKind,
    lexeme: str,
    line: ptr_uint,
    column: ptr_uint,
    start_off: ptr_uint,
    end_off: ptr_uint,
) -> void:
    tokens.push(Token(
        kind = kind,
        lexeme = lexeme,
        line = line,
        column = column,
        start_offset = start_off,
        end_offset = end_off,
    ))
