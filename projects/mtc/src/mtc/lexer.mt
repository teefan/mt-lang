import std.str as text
import std.string as string
import std.vec as vec

const KEYWORD_COUNT: int = 77
const ptr_uint_max_value: ptr_uint = 0xffffffffffffffff


public enum TokenKind: int
    eof = 0
    newline
    indent
    dedent
    bad_indent
    error
    identifier

    integer_literal
    float_literal
    character_literal
    string_literal
    cstring_literal
    format_string_literal
    heredoc_literal

    lparen
    rparen
    lbracket
    rbracket
    colon
    comma
    dot
    arrow
    dot_dot
    ellipsis
    question
    at

    plus
    minus
    star
    slash
    percent
    pipe
    amp
    caret
    tilde
    less
    less_equal
    greater
    greater_equal
    equal
    equal_equal
    bang_equal
    shift_left
    shift_right
    plus_equal
    minus_equal
    star_equal
    slash_equal
    percent_equal
    pipe_equal
    amp_equal
    caret_equal
    shift_left_equal
    shift_right_equal

    kw_align_of
    kw_and
    kw_as
    kw_async
    kw_attribute
    kw_attribute_arg
    kw_attribute_of
    kw_attributes_of
    kw_await
    kw_break
    kw_const
    kw_compiler_flag
    kw_gather
    kw_continue
    kw_function
    kw_has_attribute
    kw_defer
    kw_detach
    kw_dyn
    kw_editable
    kw_enum
    kw_else
    kw_emit
    kw_event
    kw_external
    kw_false
    kw_callable_of
    kw_fields_of
    kw_field_of
    kw_flags
    kw_fn
    kw_for
    kw_foreign
    kw_if
    kw_implements
    kw_include
    kw_in
    kw_inline
    kw_inout
    kw_import
    kw_interface
    kw_is
    kw_let
    kw_link
    kw_match
    kw_members_of
    kw_extending
    kw_module
    kw_not
    kw_null
    kw_offset_of
    kw_opaque
    kw_consuming
    kw_or
    kw_out
    kw_parallel
    kw_pass
    kw_proc
    kw_public
    kw_return
    kw_size_of
    kw_static
    kw_static_assert
    kw_struct
    kw_type
    kw_unsafe
    kw_true
    kw_union
    kw_var
    kw_variant
    kw_when
    kw_while


public struct Token:
    kind: TokenKind
    line: int
    column: int
    lexeme: string.String


const integer_suffixes: array[str, 10] = array[str, 10](
    "ub", "us", "ul", "iz", "b", "s", "i", "u", "l", "z",
)

struct Lexer:
    source: str
    index: ptr_uint
    line: int
    column: int
    indent_stack: vec.Vec[int]
    grouping_depth: int
    continuation_pending: bool
    last_kind: TokenKind


# ---------------------------------------------------------------------------
# Character classification
# ---------------------------------------------------------------------------

function is_alpha(ch: ubyte) -> bool:
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_'


function is_digit(ch: ubyte) -> bool:
    return ch >= '0' and ch <= '9'


function is_hex_digit(ch: ubyte) -> bool:
    return (ch >= '0' and ch <= '9') or (ch >= 'A' and ch <= 'F') or (ch >= 'a' and ch <= 'f')


function is_alnum(ch: ubyte) -> bool:
    return is_alpha(ch) or is_digit(ch)


function is_space(ch: ubyte) -> bool:
    return ch == ' ' or ch == '\t'


function is_newline(ch: ubyte) -> bool:
    return ch == '\n'


# ---------------------------------------------------------------------------
# Lexer cursor operations (mutable)
# ---------------------------------------------------------------------------

function advance(l: ref[Lexer]) -> ubyte:
    if l.index >= l.source.len:
        fatal(c"lexer advance past end")
    let ch = unsafe: ubyte<-read(l.source.data + l.index)
    l.index += 1
    l.column += 1
    return ch


function peek_current(l: ref[Lexer]) -> ubyte:
    if l.index >= l.source.len:
        return 0
    return unsafe: ubyte<-read(l.source.data + l.index)


function peek_at(l: ref[Lexer], offset: ptr_uint) -> ubyte:
    let pos = l.index + offset
    if pos >= l.source.len:
        return 0
    return unsafe: ubyte<-read(l.source.data + pos)


function is_at_end(l: ref[Lexer]) -> bool:
    return l.index >= l.source.len


function skip_to_eol(l: ref[Lexer]) -> void:
    while not is_at_end(l) and not is_newline(peek_current(l)):
        let _ = advance(l)


function skip_line(l: ref[Lexer]) -> void:
    while not is_at_end(l) and not is_newline(peek_current(l)):
        let _ = advance(l)
    if not is_at_end(l) and is_newline(peek_current(l)):
        let _ = advance(l)
        l.line += 1
        l.column = 1


function skip_blank_lines(l: ref[Lexer]) -> void:
    while not is_at_end(l) and is_newline(peek_current(l)):
        let _ = advance(l)
        l.line += 1
        l.column = 1


function push_token(l: ref[Lexer], tokens: ref[vec.Vec[Token]], kind: TokenKind, lexeme: str) -> void:
    let token = Token(
        kind = kind,
        line = l.line,
        column = l.column,
        lexeme = string.String.from_str(lexeme),
    )
    tokens.push(token)


function emit_token(l: ref[Lexer], tokens: ref[vec.Vec[Token]], kind: TokenKind, start: ptr_uint, line: int, column: int) -> void:
    let len = l.index - start
    var lexeme_str = unsafe: str(data = l.source.data + start, len = len)
    let token = Token(
        kind = kind,
        line = line,
        column = column,
        lexeme = string.String.from_str(lexeme_str),
    )
    tokens.push(token)


# ---------------------------------------------------------------------------
# Indentation
# ---------------------------------------------------------------------------

function count_indent(source: str, start: ptr_uint) -> int:
    var count: int = 0
    var pos = start
    while pos < source.len:
        let ch = unsafe: ubyte<-read(source.data + pos)
        if ch == 32:
            count += 1
        else if ch == 9:
            return -1
        else:
            break
        pos += 1
    return count


function handle_indentation(l: ref[Lexer], tokens: ref[vec.Vec[Token]]) -> void:
    if is_at_end(l):
        return

    if l.grouping_depth > 0:
        return

    if l.continuation_pending:
        l.continuation_pending = false
        l.index += ptr_uint<-l.indent_stack.len()
        # Consume spaces on continuation line without emitting tokens
        var indent = count_indent(l.source, l.index)
        if indent > 0:
            l.index += ptr_uint<-indent
            l.column += indent
        return

    var indent = count_indent(l.source, l.index)
    if indent == -1:
        push_token(l, tokens, TokenKind.bad_indent, "tab")
        skip_line(l)
        return

    if indent % 4 != 0:
        push_token(l, tokens, TokenKind.bad_indent, "indent")
        skip_line(l)
        return

    var current: int = 0
    if l.indent_stack.len() > 0:
        let last_ptr = l.indent_stack.last() else:
            fatal(c"lexer indent stack corrupt")
        current = unsafe: int<-read(last_ptr)

    if indent > current:
        if indent != current + 4:
            push_token(l, tokens, TokenKind.bad_indent, "indent-step")
            skip_line(l)
            return

        l.indent_stack.push(indent)
        push_token(l, tokens, TokenKind.indent, "")

    else if indent < current:
        while l.indent_stack.len() > 0:
            let top_ptr = l.indent_stack.last() else:
                break
            let top = unsafe: int<-read(top_ptr)
            if top <= indent:
                break

            let _ = l.indent_stack.pop()
            push_token(l, tokens, TokenKind.dedent, "")

    l.index += ptr_uint<-indent
    l.column += indent


# ---------------------------------------------------------------------------
# Number scanning
# ---------------------------------------------------------------------------

function skip_digits(l: ref[Lexer]) -> void:
    while not is_at_end(l) and (is_digit(peek_current(l)) or peek_current(l) == '_'):
        let _ = advance(l)


function skip_hex_digits(l: ref[Lexer]) -> void:
    while not is_at_end(l) and (is_hex_digit(peek_current(l)) or peek_current(l) == '_'):
        let _ = advance(l)


function skip_number_suffix(l: ref[Lexer]) -> void:
    if not is_at_end(l) and is_alpha(peek_current(l)):
        var suffix_start = l.index
        while not is_at_end(l) and is_alnum(peek_current(l)):
            let _ = advance(l)
        var suffix_len = l.index - suffix_start
        if suffix_len > 0:
            let next_ch = if not is_at_end(l): peek_current(l) else: 0
            if is_alnum(next_ch):
                l.index = suffix_start
                return
            let suffix = unsafe: str(data = l.source.data + suffix_start, len = suffix_len)
            var valid = false
            var vi: ptr_uint = 0
            while vi < 10:
                if suffix == integer_suffixes[vi]:
                    valid = true
                    break
                vi += 1
            if not valid and not (suffix == "f") and not (suffix == "d"):
                l.index = suffix_start


function scan_number(l: ref[Lexer], tokens: ref[vec.Vec[Token]]) -> void:
    let start = l.index
    let start_line = l.line
    let start_col = l.column
    var is_float = false

    if peek_current(l) == '0':
        let ch1 = peek_at(l, 1)
        if ch1 == 'x' or ch1 == 'X':
            let _ = advance(l)
            let _ = advance(l)
            skip_hex_digits(l)
            skip_number_suffix(l)
            emit_token(l, tokens, TokenKind.integer_literal, start, start_line, start_col)
            return

        if ch1 == 'b' or ch1 == 'B':
            let _ = advance(l)
            let _ = advance(l)
            while not is_at_end(l) and (peek_current(l) == '0' or peek_current(l) == '1' or peek_current(l) == '_'):
                let _ = advance(l)
            skip_number_suffix(l)
            emit_token(l, tokens, TokenKind.integer_literal, start, start_line, start_col)
            return

    skip_digits(l)

    if not is_at_end(l) and peek_current(l) == '.' and is_digit(peek_at(l, 1)):
        is_float = true
        let _ = advance(l)
        skip_digits(l)

    if not is_at_end(l) and (peek_current(l) == 'e' or peek_current(l) == 'E'):
        is_float = true
        let _ = advance(l)
        if not is_at_end(l) and (peek_current(l) == '+' or peek_current(l) == '-'):
            let _ = advance(l)
        skip_digits(l)

    skip_number_suffix(l)

    if is_float:
        emit_token(l, tokens, TokenKind.float_literal, start, start_line, start_col)
        l.last_kind = TokenKind.float_literal
    else:
        emit_token(l, tokens, TokenKind.integer_literal, start, start_line, start_col)
        l.last_kind = TokenKind.integer_literal
    l.continuation_pending = false


# ---------------------------------------------------------------------------
# Identifiers and keywords
# ---------------------------------------------------------------------------

function lookup_keyword(l: ref[Lexer], id_start: ptr_uint) -> TokenKind:
    let id_len = l.index - id_start
    if id_len == 0:
        return TokenKind.identifier

    let id = unsafe: str(data = l.source.data + id_start, len = id_len)

    let keywords: array[str, 77] = array[str, 77](
        "align_of", "and", "as", "async", "attribute", "attribute_arg",
        "attribute_of", "attributes_of", "await", "break", "const",
        "compiler_flag", "gather", "continue", "function", "has_attribute",
        "defer", "detach", "dyn", "editable", "enum", "else", "emit",
        "event", "external", "false", "callable_of", "fields_of",
        "field_of", "flags", "fn", "for", "foreign", "if", "implements",
        "include", "in", "inline", "inout", "import", "interface", "is",
        "let", "link", "match", "members_of", "extending", "module", "not",
        "null", "offset_of", "opaque", "consuming", "or", "out", "parallel",
        "pass", "proc", "public", "return", "size_of", "static",
        "static_assert", "struct", "type", "unsafe", "true", "union", "var",
        "variant", "when", "while",
    )

    let kinds: array[TokenKind, 77] = array[TokenKind, 77](
        TokenKind.kw_align_of, TokenKind.kw_and, TokenKind.kw_as,
        TokenKind.kw_async, TokenKind.kw_attribute, TokenKind.kw_attribute_arg,
        TokenKind.kw_attribute_of, TokenKind.kw_attributes_of, TokenKind.kw_await,
        TokenKind.kw_break, TokenKind.kw_const, TokenKind.kw_compiler_flag,
        TokenKind.kw_gather, TokenKind.kw_continue, TokenKind.kw_function,
        TokenKind.kw_has_attribute, TokenKind.kw_defer, TokenKind.kw_detach,
        TokenKind.kw_dyn, TokenKind.kw_editable, TokenKind.kw_enum,
        TokenKind.kw_else, TokenKind.kw_emit, TokenKind.kw_event,
        TokenKind.kw_external, TokenKind.kw_false, TokenKind.kw_callable_of,
        TokenKind.kw_fields_of, TokenKind.kw_field_of, TokenKind.kw_flags,
        TokenKind.kw_fn, TokenKind.kw_for, TokenKind.kw_foreign, TokenKind.kw_if,
        TokenKind.kw_implements, TokenKind.kw_include, TokenKind.kw_in,
        TokenKind.kw_inline, TokenKind.kw_inout, TokenKind.kw_import,
        TokenKind.kw_interface, TokenKind.kw_is, TokenKind.kw_let,
        TokenKind.kw_link, TokenKind.kw_match, TokenKind.kw_members_of,
        TokenKind.kw_extending, TokenKind.kw_module, TokenKind.kw_not,
        TokenKind.kw_null, TokenKind.kw_offset_of, TokenKind.kw_opaque,
        TokenKind.kw_consuming, TokenKind.kw_or, TokenKind.kw_out,
        TokenKind.kw_parallel, TokenKind.kw_pass, TokenKind.kw_proc,
        TokenKind.kw_public, TokenKind.kw_return, TokenKind.kw_size_of,
        TokenKind.kw_static, TokenKind.kw_static_assert, TokenKind.kw_struct,
        TokenKind.kw_type, TokenKind.kw_unsafe, TokenKind.kw_true,
        TokenKind.kw_union, TokenKind.kw_var, TokenKind.kw_variant,
        TokenKind.kw_when, TokenKind.kw_while,
    )

    var i: ptr_uint = 0
    while i < 77:
        if id == keywords[i]:
            return kinds[i]
        i += 1

    return TokenKind.identifier


# ---------------------------------------------------------------------------
# String scanning
# ---------------------------------------------------------------------------

function scan_escape(l: ref[Lexer], is_char: bool) -> bool:
    if is_at_end(l):
        return false
    let ch = peek_current(l)
    if ch == 'n' or ch == 'r' or ch == 't' or ch == '\\' or ch == '0':
        let _ = advance(l)
        return true
    else if ch == '\'' or ch == '"':
        let _ = advance(l)
        return true
    else if ch == 'x':
        let _ = advance(l)
        if is_char:
            if is_at_end(l) or not is_hex_digit(peek_current(l)):
                return false
            let _ = advance(l)
            if is_at_end(l) or not is_hex_digit(peek_current(l)):
                return false
            let _ = advance(l)
        else:
            if not is_at_end(l) and is_hex_digit(peek_current(l)):
                let _ = advance(l)
            if not is_at_end(l) and is_hex_digit(peek_current(l)):
                let _ = advance(l)
        return true
    let _ = advance(l)
    return true


function scan_string(l: ref[Lexer], tokens: ref[vec.Vec[Token]], kind: TokenKind) -> void:
    let start = l.index
    let start_line = l.line
    let start_col = l.column
    let _ = advance(l)

    while not is_at_end(l) and peek_current(l) != 34:
        if is_newline(peek_current(l)):
            emit_token(l, tokens, TokenKind.error, start, start_line, start_col)
            return
        if peek_current(l) == 92:
            let _ = advance(l)
            let _ = scan_escape(l, false)
        else:
            let _ = advance(l)

    if is_at_end(l):
        emit_token(l, tokens, TokenKind.error, start, start_line, start_col)
        return

    let _ = advance(l)
    emit_token(l, tokens, kind, start, start_line, start_col)


function scan_char(l: ref[Lexer], tokens: ref[vec.Vec[Token]]) -> void:
    let start = l.index
    let start_line = l.line
    let start_col = l.column
    let _ = advance(l)

    if is_at_end(l) or is_newline(peek_current(l)):
        emit_token(l, tokens, TokenKind.error, start, start_line, start_col)
        return

    if peek_current(l) == 92:
        let _ = advance(l)
        if not scan_escape(l, true):
            emit_token(l, tokens, TokenKind.error, start, start_line, start_col)
            skip_to_eol(l)
            return
    else:
        let _ = advance(l)

    if is_at_end(l) or peek_current(l) != 39:
        emit_token(l, tokens, TokenKind.error, start, start_line, start_col)
        skip_to_eol(l)
        return

    let _ = advance(l)
    emit_token(l, tokens, TokenKind.character_literal, start, start_line, start_col)


# ---------------------------------------------------------------------------
# Heredoc scanning
# ---------------------------------------------------------------------------

function scan_heredoc(l: ref[Lexer], tokens: ref[vec.Vec[Token]], token_kind: TokenKind) -> void:
    let start = l.index
    let start_line = l.line
    let start_col = l.column

    let _ = advance(l)
    let _ = advance(l)
    let _ = advance(l)

    var tag_start = l.index
    while not is_at_end(l) and not is_newline(peek_current(l)) and not is_space(peek_current(l)):
        let _ = advance(l)
    var tag_end = l.index

    if tag_end == tag_start:
        emit_token(l, tokens, TokenKind.error, start, start_line, start_col)
        return

    skip_line(l)

    var content_start = l.index
    var tag_str = unsafe: str(data = l.source.data + tag_start, len = tag_end - tag_start)

    var found = false
    while not is_at_end(l):
        if l.index + tag_str.len <= l.source.len:
            var matches = true
            var ti: ptr_uint = 0
            while ti < tag_str.len:
                let ch1 = unsafe: ubyte<-read(tag_str.data + ti)
                let ch2 = unsafe: ubyte<-read(l.source.data + l.index + ti)
                if ch1 != ch2:
                    matches = false
                    break
                ti += 1

            if matches:
                let after_idx = l.index + tag_str.len
                var is_end = false
                if after_idx >= l.source.len:
                    is_end = true
                else:
                    let after_ch = unsafe: ubyte<-read(l.source.data + after_idx)
                    is_end = is_newline(after_ch) or is_space(after_ch)
                if is_end:
                    found = true
                    break

        if is_newline(peek_current(l)):
            let _ = advance(l)
            l.line += 1
            l.column = 1
        else:
            let _ = advance(l)

    if not found:
        emit_token(l, tokens, TokenKind.error, start, start_line, start_col)
        return

    var content_end = l.index

    l.index += tag_str.len
    if not is_at_end(l) and is_newline(peek_current(l)):
        let _ = advance(l)
        l.line += 1
        l.column = 1

    let raw_len = content_end - content_start
    var margin = heredoc_margin(l.source, content_start, content_end)
    var lexeme_str = dedent_heredoc(l.source, content_start, content_end, margin)
    let token = Token(
        kind = token_kind,
        line = start_line,
        column = start_col,
        lexeme = lexeme_str,
    )
    tokens.push(token)


function heredoc_margin(source: str, start: ptr_uint, end: ptr_uint) -> ptr_uint:
    var min_space: ptr_uint = ptr_uint_max_value
    var pos = start
    var line_spaces: ptr_uint = 0
    var in_leading = true

    while pos < end:
        let ch = unsafe: ubyte<-read(source.data + pos)
        if is_newline(ch):
            if line_spaces < min_space:
                min_space = line_spaces
            line_spaces = 0
            in_leading = true
            pos += 1
        else if in_leading and ch == ' ':
            line_spaces += 1
            pos += 1
        else:
            in_leading = false
            pos += 1

    if in_leading and line_spaces > 0:
        if line_spaces < min_space:
            min_space = line_spaces

    if min_space == ptr_uint_max_value:
        return 0

    return min_space


function dedent_heredoc(source: str, start: ptr_uint, end: ptr_uint, margin: ptr_uint) -> string.String:
    if margin == 0:
        let raw = unsafe: str(data = source.data + start, len = end - start)
        return string.String.from_str(raw)

    var result = string.String.with_capacity(end - start)
    var pos = start
    var in_margin = true
    var margin_count: ptr_uint = 0

    while pos < end:
        let ch = unsafe: ubyte<-read(source.data + pos)
        if is_newline(ch):
            result.push_byte('\n')
            pos += 1
            in_margin = true
            margin_count = 0
        else if in_margin and margin_count < margin and ch == ' ':
            pos += 1
            margin_count += 1
        else:
            in_margin = false
            result.push_byte(ch)
            pos += 1

    return result


# ---------------------------------------------------------------------------
# Operator scanning
# ---------------------------------------------------------------------------

function scan_operator(l: ref[Lexer], tokens: ref[vec.Vec[Token]]) -> void:
    let start = l.index
    let start_line = l.line
    let start_col = l.column
    let ch = advance(l)
    let next = peek_current(l)
    var kind = TokenKind.error

    if ch == '(':
        kind = TokenKind.lparen
        push_token(l, tokens, kind, "(")
    else if ch == ')':
        kind = TokenKind.rparen
        push_token(l, tokens, kind, ")")
    else if ch == '[':
        kind = TokenKind.lbracket
        push_token(l, tokens, kind, "[")
    else if ch == ']':
        kind = TokenKind.rbracket
        push_token(l, tokens, kind, "]")
    else if ch == ':':
        kind = TokenKind.colon
        push_token(l, tokens, kind, ":")
    else if ch == ',':
        kind = TokenKind.comma
        push_token(l, tokens, kind, ",")
    else if ch == '~':
        kind = TokenKind.tilde
        push_token(l, tokens, kind, "~")
    else if ch == '?':
        kind = TokenKind.question
        push_token(l, tokens, kind, "?")
    else if ch == '@':
        kind = TokenKind.at
        push_token(l, tokens, kind, "@")

    else if ch == '.':
        if next == '.':
            let _ = advance(l)
            if peek_current(l) == '.':
                let _ = advance(l)
                kind = TokenKind.ellipsis
            else:
                kind = TokenKind.dot_dot
        else:
            kind = TokenKind.dot
        let lexeme_str = unsafe: str(data = l.source.data + start, len = l.index - start)
        let token = Token(kind = kind, line = start_line, column = start_col, lexeme = string.String.from_str(lexeme_str))
        tokens.push(token)

    else if ch == '-':
        if next == '>':
            let _ = advance(l)
            kind = TokenKind.arrow
        else if next == '=':
            let _ = advance(l)
            kind = TokenKind.minus_equal
        else:
            kind = TokenKind.minus
        let lexeme_str = unsafe: str(data = l.source.data + start, len = l.index - start)
        let token = Token(kind = kind, line = start_line, column = start_col, lexeme = string.String.from_str(lexeme_str))
        tokens.push(token)

    else if ch == '+':
        if next == '=':
            let _ = advance(l)
            kind = TokenKind.plus_equal
        else:
            kind = TokenKind.plus
        let lexeme_str = unsafe: str(data = l.source.data + start, len = l.index - start)
        let token = Token(kind = kind, line = start_line, column = start_col, lexeme = string.String.from_str(lexeme_str))
        tokens.push(token)

    else if ch == '*':
        if next == '=':
            let _ = advance(l)
            kind = TokenKind.star_equal
        else:
            kind = TokenKind.star
        let lexeme_str = unsafe: str(data = l.source.data + start, len = l.index - start)
        let token = Token(kind = kind, line = start_line, column = start_col, lexeme = string.String.from_str(lexeme_str))
        tokens.push(token)

    else if ch == '/':
        if next == '=':
            let _ = advance(l)
            kind = TokenKind.slash_equal
        else:
            kind = TokenKind.slash
        let lexeme_str = unsafe: str(data = l.source.data + start, len = l.index - start)
        let token = Token(kind = kind, line = start_line, column = start_col, lexeme = string.String.from_str(lexeme_str))
        tokens.push(token)

    else if ch == '%':
        if next == '=':
            let _ = advance(l)
            kind = TokenKind.percent_equal
        else:
            kind = TokenKind.percent
        let lexeme_str = unsafe: str(data = l.source.data + start, len = l.index - start)
        let token = Token(kind = kind, line = start_line, column = start_col, lexeme = string.String.from_str(lexeme_str))
        tokens.push(token)

    else if ch == '|':
        if next == '=':
            let _ = advance(l)
            kind = TokenKind.pipe_equal
        else:
            kind = TokenKind.pipe
        let lexeme_str = unsafe: str(data = l.source.data + start, len = l.index - start)
        let token = Token(kind = kind, line = start_line, column = start_col, lexeme = string.String.from_str(lexeme_str))
        tokens.push(token)

    else if ch == '&':
        if next == '=':
            let _ = advance(l)
            kind = TokenKind.amp_equal
        else:
            kind = TokenKind.amp
        let lexeme_str = unsafe: str(data = l.source.data + start, len = l.index - start)
        let token = Token(kind = kind, line = start_line, column = start_col, lexeme = string.String.from_str(lexeme_str))
        tokens.push(token)

    else if ch == '^':
        if next == '=':
            let _ = advance(l)
            kind = TokenKind.caret_equal
        else:
            kind = TokenKind.caret
        let lexeme_str = unsafe: str(data = l.source.data + start, len = l.index - start)
        let token = Token(kind = kind, line = start_line, column = start_col, lexeme = string.String.from_str(lexeme_str))
        tokens.push(token)

    else if ch == '!':
        if next == '=':
            let _ = advance(l)
            kind = TokenKind.bang_equal
        else:
            kind = TokenKind.error
        let lexeme_str = unsafe: str(data = l.source.data + start, len = l.index - start)
        let token = Token(kind = kind, line = start_line, column = start_col, lexeme = string.String.from_str(lexeme_str))
        tokens.push(token)

    else if ch == '=':
        if next == '=':
            let _ = advance(l)
            kind = TokenKind.equal_equal
        else:
            kind = TokenKind.equal
        let lexeme_str = unsafe: str(data = l.source.data + start, len = l.index - start)
        let token = Token(kind = kind, line = start_line, column = start_col, lexeme = string.String.from_str(lexeme_str))
        tokens.push(token)

    else if ch == '<':
        if next == '<':
            let _ = advance(l)
            if peek_current(l) == '=':
                let _ = advance(l)
                kind = TokenKind.shift_left_equal
            else:
                kind = TokenKind.shift_left
        else if next == '=':
            let _ = advance(l)
            kind = TokenKind.less_equal
        else:
            kind = TokenKind.less
        let lexeme_str = unsafe: str(data = l.source.data + start, len = l.index - start)
        let token = Token(kind = kind, line = start_line, column = start_col, lexeme = string.String.from_str(lexeme_str))
        tokens.push(token)

    else if ch == '>':
        if next == '>':
            let _ = advance(l)
            if peek_current(l) == '=':
                let _ = advance(l)
                kind = TokenKind.shift_right_equal
            else:
                kind = TokenKind.shift_right
        else if next == '=':
            let _ = advance(l)
            kind = TokenKind.greater_equal
        else:
            kind = TokenKind.greater
        let lexeme_str = unsafe: str(data = l.source.data + start, len = l.index - start)
        let token = Token(kind = kind, line = start_line, column = start_col, lexeme = string.String.from_str(lexeme_str))
        tokens.push(token)

    else:
        kind = TokenKind.error

    if kind == TokenKind.lparen or kind == TokenKind.lbracket:
        l.grouping_depth += 1
    else if kind == TokenKind.rparen or kind == TokenKind.rbracket:
        if l.grouping_depth > 0:
            l.grouping_depth -= 1

    l.last_kind = kind
    l.continuation_pending = false
    if is_continuation_op(kind) and l.grouping_depth == 0:
        l.continuation_pending = true


# ---------------------------------------------------------------------------
# Main scan function
# ---------------------------------------------------------------------------

function scan_token(l: ref[Lexer], tokens: ref[vec.Vec[Token]]) -> void:
    if is_at_end(l):
        return

    var ch = peek_current(l)

    if is_newline(ch):
        let _ = advance(l)
        l.line += 1
        l.column = 1

        if l.grouping_depth > 0:
            return

        var cont = l.continuation_pending
        var last_is_cont = is_continuation_op(l.last_kind) and l.grouping_depth == 0

        if cont or last_is_cont:
            l.continuation_pending = true
            skip_blank_lines(l)
            return

        push_token(l, tokens, TokenKind.newline, "")
        skip_blank_lines(l)
        handle_indentation(l, tokens)
        return

    if is_space(ch):
        let _ = advance(l)
        return

    if ch == '#':
        skip_to_eol(l)
        return

    if ch == '"':
        scan_string(l, tokens, TokenKind.string_literal)
        l.last_kind = TokenKind.string_literal
        l.continuation_pending = false
        return

    if ch == '\'':
        scan_char(l, tokens)
        l.last_kind = TokenKind.character_literal
        l.continuation_pending = false
        return

    if is_alpha(ch):
        let id_start = l.index
        let id_line = l.line
        let id_col = l.column
        while not is_at_end(l) and is_alnum(peek_current(l)):
            let _ = advance(l)
        let id_len = l.index - id_start
        let id = unsafe: str(data = l.source.data + id_start, len = id_len)

        if id == "c" and not is_at_end(l) and peek_current(l) == '"':
            scan_string(l, tokens, TokenKind.cstring_literal)
            l.last_kind = TokenKind.cstring_literal
            l.continuation_pending = false
            return
        if id == "c" and not is_at_end(l):
            let p = peek_current(l)
            if p == '<':
                scan_heredoc(l, tokens, TokenKind.heredoc_literal)
                l.last_kind = TokenKind.heredoc_literal
                l.continuation_pending = false
                return

        if id == "f" and not is_at_end(l) and peek_current(l) == '"':
            scan_string(l, tokens, TokenKind.format_string_literal)
            l.last_kind = TokenKind.format_string_literal
            l.continuation_pending = false
            return
        if id == "f" and not is_at_end(l):
            let p = peek_current(l)
            if p == '<':
                scan_heredoc(l, tokens, TokenKind.format_string_literal)
                l.last_kind = TokenKind.format_string_literal
                l.continuation_pending = false
                return

        let kind = lookup_keyword(l, id_start)
        let token = Token(
            kind = kind,
            line = id_line,
            column = id_col,
            lexeme = string.String.from_str(id),
        )
        tokens.push(token)
        l.last_kind = kind
        l.continuation_pending = false
        return

    if is_digit(ch):
        scan_number(l, tokens)
        return

    if ch == '<' and peek_at(l, 1) == '<' and peek_at(l, 2) == '-':
        scan_heredoc(l, tokens, TokenKind.heredoc_literal)
        l.last_kind = TokenKind.heredoc_literal
        l.continuation_pending = false
        return

    if ch == '<' and peek_at(l, 1) == '<' and peek_at(l, 2) == 'f' and peek_at(l, 3) == '-':
        scan_heredoc(l, tokens, TokenKind.format_string_literal)
        l.last_kind = TokenKind.format_string_literal
        l.continuation_pending = false
        return

    scan_operator(l, tokens)


# ---------------------------------------------------------------------------
# Line continuation check
# ---------------------------------------------------------------------------

function is_continuation_op(kind: TokenKind) -> bool:
    return (
        kind == TokenKind.dot_dot
        or kind == TokenKind.plus or kind == TokenKind.minus
        or kind == TokenKind.star or kind == TokenKind.slash
        or kind == TokenKind.percent or kind == TokenKind.pipe
        or kind == TokenKind.amp or kind == TokenKind.caret
        or kind == TokenKind.kw_or or kind == TokenKind.kw_and
        or kind == TokenKind.equal_equal or kind == TokenKind.bang_equal
        or kind == TokenKind.less or kind == TokenKind.less_equal
        or kind == TokenKind.greater or kind == TokenKind.greater_equal
        or kind == TokenKind.shift_left or kind == TokenKind.shift_right
    )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

public function lex(source: str) -> vec.Vec[Token]:
    var tokens = vec.Vec[Token].create()
    var state = Lexer(
        source = source,
        index = 0,
        line = 1,
        column = 1,
        indent_stack = vec.Vec[int].create(),
        grouping_depth = 0,
        continuation_pending = false,
        last_kind = TokenKind.eof,
    )
    let state_ref = ref_of(state)

    while not is_at_end(state_ref):
        scan_token(state_ref, ref_of(tokens))

    while state.indent_stack.len() > 0:
        let _ = state.indent_stack.pop()
        push_token(state_ref, ref_of(tokens), TokenKind.dedent, "")

    state.indent_stack.release()
    push_token(state_ref, ref_of(tokens), TokenKind.eof, "")
    return tokens


public function kind_name(kind: TokenKind) -> str:
    if kind == TokenKind.eof:
        return "eof"
    if kind == TokenKind.newline:
        return "newline"
    if kind == TokenKind.indent:
        return "indent"
    if kind == TokenKind.dedent:
        return "dedent"
    if kind == TokenKind.bad_indent:
        return "bad_indent"
    if kind == TokenKind.error:
        return "error"
    if kind == TokenKind.identifier:
        return "id"
    if kind == TokenKind.integer_literal:
        return "int"
    if kind == TokenKind.float_literal:
        return "float"
    if kind == TokenKind.character_literal:
        return "char"
    if kind == TokenKind.string_literal:
        return "str"
    if kind == TokenKind.cstring_literal:
        return "cstr"
    if kind == TokenKind.format_string_literal:
        return "fstr"
    if kind == TokenKind.heredoc_literal:
        return "heredoc"
    if kind == TokenKind.lparen:
        return "("
    if kind == TokenKind.rparen:
        return ")"
    if kind == TokenKind.lbracket:
        return "["
    if kind == TokenKind.rbracket:
        return "]"
    if kind == TokenKind.colon:
        return ":"
    if kind == TokenKind.comma:
        return ","
    if kind == TokenKind.dot:
        return "."
    if kind == TokenKind.arrow:
        return "->"
    if kind == TokenKind.dot_dot:
        return ".."
    if kind == TokenKind.ellipsis:
        return "..."
    if kind == TokenKind.question:
        return "?"
    if kind == TokenKind.at:
        return "@"
    if kind == TokenKind.plus:
        return "+"
    if kind == TokenKind.minus:
        return "-"
    if kind == TokenKind.star:
        return "*"
    if kind == TokenKind.slash:
        return "/"
    if kind == TokenKind.percent:
        return "%"
    if kind == TokenKind.pipe:
        return "|"
    if kind == TokenKind.amp:
        return "&"
    if kind == TokenKind.caret:
        return "^"
    if kind == TokenKind.tilde:
        return "~"
    if kind == TokenKind.less:
        return "<"
    if kind == TokenKind.less_equal:
        return "<="
    if kind == TokenKind.greater:
        return ">"
    if kind == TokenKind.greater_equal:
        return ">="
    if kind == TokenKind.equal:
        return "="
    if kind == TokenKind.equal_equal:
        return "=="
    if kind == TokenKind.bang_equal:
        return "!="
    if kind == TokenKind.shift_left:
        return "<<"
    if kind == TokenKind.shift_right:
        return ">>"
    if kind == TokenKind.plus_equal:
        return "+="
    if kind == TokenKind.minus_equal:
        return "-="
    if kind == TokenKind.star_equal:
        return "*="
    if kind == TokenKind.slash_equal:
        return "/="
    if kind == TokenKind.percent_equal:
        return "%="
    if kind == TokenKind.pipe_equal:
        return "|="
    if kind == TokenKind.amp_equal:
        return "&="
    if kind == TokenKind.caret_equal:
        return "^="
    if kind == TokenKind.shift_left_equal:
        return "<<="
    if kind == TokenKind.shift_right_equal:
        return ">>="
    return lookup_kind_name(kind)


function lookup_kind_name(kind: TokenKind) -> str:
    let names: array[str, 77] = array[str, 77](
        "align_of", "and", "as", "async", "attribute", "attribute_arg",
        "attribute_of", "attributes_of", "await", "break", "const",
        "compiler_flag", "gather", "continue", "function", "has_attribute",
        "defer", "detach", "dyn", "editable", "enum", "else", "emit",
        "event", "external", "false", "callable_of", "fields_of",
        "field_of", "flags", "fn", "for", "foreign", "if", "implements",
        "include", "in", "inline", "inout", "import", "interface", "is",
        "let", "link", "match", "members_of", "extending", "module", "not",
        "null", "offset_of", "opaque", "consuming", "or", "out", "parallel",
        "pass", "proc", "public", "return", "size_of", "static",
        "static_assert", "struct", "type", "unsafe", "true", "union", "var",
        "variant", "when", "while",
    )
    let kinds: array[TokenKind, 77] = array[TokenKind, 77](
        TokenKind.kw_align_of, TokenKind.kw_and, TokenKind.kw_as,
        TokenKind.kw_async, TokenKind.kw_attribute, TokenKind.kw_attribute_arg,
        TokenKind.kw_attribute_of, TokenKind.kw_attributes_of, TokenKind.kw_await,
        TokenKind.kw_break, TokenKind.kw_const, TokenKind.kw_compiler_flag,
        TokenKind.kw_gather, TokenKind.kw_continue, TokenKind.kw_function,
        TokenKind.kw_has_attribute, TokenKind.kw_defer, TokenKind.kw_detach,
        TokenKind.kw_dyn, TokenKind.kw_editable, TokenKind.kw_enum,
        TokenKind.kw_else, TokenKind.kw_emit, TokenKind.kw_event,
        TokenKind.kw_external, TokenKind.kw_false, TokenKind.kw_callable_of,
        TokenKind.kw_fields_of, TokenKind.kw_field_of, TokenKind.kw_flags,
        TokenKind.kw_fn, TokenKind.kw_for, TokenKind.kw_foreign, TokenKind.kw_if,
        TokenKind.kw_implements, TokenKind.kw_include, TokenKind.kw_in,
        TokenKind.kw_inline, TokenKind.kw_inout, TokenKind.kw_import,
        TokenKind.kw_interface, TokenKind.kw_is, TokenKind.kw_let,
        TokenKind.kw_link, TokenKind.kw_match, TokenKind.kw_members_of,
        TokenKind.kw_extending, TokenKind.kw_module, TokenKind.kw_not,
        TokenKind.kw_null, TokenKind.kw_offset_of, TokenKind.kw_opaque,
        TokenKind.kw_consuming, TokenKind.kw_or, TokenKind.kw_out,
        TokenKind.kw_parallel, TokenKind.kw_pass, TokenKind.kw_proc,
        TokenKind.kw_public, TokenKind.kw_return, TokenKind.kw_size_of,
        TokenKind.kw_static, TokenKind.kw_static_assert, TokenKind.kw_struct,
        TokenKind.kw_type, TokenKind.kw_unsafe, TokenKind.kw_true,
        TokenKind.kw_union, TokenKind.kw_var, TokenKind.kw_variant,
        TokenKind.kw_when, TokenKind.kw_while,
    )
    var i: ptr_uint = 0
    while i < 77:
        if kind == kinds[i]:
            return names[i]
        i += 1
    return "kw"
