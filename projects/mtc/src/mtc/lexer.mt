# Lexer for the self-hosting Milk Tea compiler.
#
# Line-by-line indentation-based lexer, mirroring the architecture of the
# Ruby lib/milk_tea/core/lexer.rb.

import mtc.token
import std.str
import std.vec

public struct Lexer:
    source: str
    tokens: vec.Vec[token.Token]
    indent_depth: ptr_uint
    pos: ptr_uint
    line: int
    grouping_depth: ptr_uint
    grouping_start_line: int

extending Lexer:
    public static function from_source(source: str) -> Lexer:
        return Lexer(
            source = source,
            tokens = vec.Vec[token.Token].create(),
            indent_depth = 0z,
            pos = 0z,
            line = 1,
            grouping_depth = 0z,
            grouping_start_line = 0,
        )

    # ── public API ──

    public editable function tokenize() -> void:
        while this.pos < this.source.len:
            this.consume_line()
        this.close_remaining_blocks()
        this.push_token(token.TokenKind.eof, "", this.line, 1, this.source.len)

    public function finish() -> vec.Vec[token.Token]:
        return this.tokens

    # ── line processing ──

    editable function consume_line() -> void:
        let line_start = this.pos
        let line_end = this.find_line_end()
        let has_newline = line_end < this.source.len
        let line_len = line_end - line_start

        if line_len == 0 or (line_len == 1 and this.source.byte_at(line_start) == '\r'):
            this.pos = line_end
            if has_newline:
                this.pos += 1
            this.line += 1
            return

        if this.start_of_comment(line_start, line_end):
            this.pos = line_end
            if has_newline:
                this.pos += 1
            this.line += 1
            return

        let indent_spaces = this.count_leading_spaces(line_start, line_end)
        let content_start = line_start + indent_spaces

        if this.grouping_depth == 0z:
            this.emit_indentation(indent_spaces)

        this.pos = content_start
        while this.pos < line_end:
            if this.source.byte_at(this.pos) == ' ':
                this.advance()
            else:
                this.scan_token(line_start)

        this.pos = line_end
        if has_newline:
            this.pos += 1

        if this.grouping_depth == 0z:
            this.push_token(token.TokenKind.newline, "\n", this.line, int<-(line_len) + 1, line_start + line_len)

        this.line += 1

    function find_line_end() -> ptr_uint:
        var p: ptr_uint = this.pos
        while p < this.source.len:
            let b = this.source.byte_at(p)
            if b == '\n':
                return p
            p += 1
        return p

    function count_leading_spaces(line_start: ptr_uint, line_end: ptr_uint) -> ptr_uint:
        var p: ptr_uint = line_start
        while p < line_end:
            let b = this.source.byte_at(p)
            if b == ' ':
                p += 1
            else if b == '\t':
                let col = p - line_start + 1
                fatal(f"tabs are not allowed; use 4 spaces for indentation at #{this.line}:#{col}")
            else:
                break
        return p - line_start

    function start_of_comment(line_start: ptr_uint, line_end: ptr_uint) -> bool:
        var p: ptr_uint = line_start
        while p < line_end:
            let b = this.source.byte_at(p)
            if b == ' ' or b == '\r':
                p += 1
            else if b == '#':
                return true
            else:
                return false
        return false

    # ── indentation ──

    editable function emit_indentation(spaces: ptr_uint) -> void:
        if spaces % 4 != 0:
            fatal(f"indentation must use multiples of 4 spaces at #{this.line}:#{spaces + 1}")

        let expected = this.indent_depth * 4z
        let col: int = 1

        if spaces == expected:
            return

        if spaces > expected:
            if spaces != expected + 4z:
                fatal(f"indentation may only increase by 4 spaces at a time at #{this.line}:1")
            this.indent_depth += 1
            this.push_token(token.TokenKind.indent, "", this.line, col, this.pos)
            return

        while spaces < this.indent_depth * 4z:
            this.indent_depth -= 1
            this.push_token(token.TokenKind.dedent, "", this.line, col, this.pos)

        if spaces != this.indent_depth * 4z:
            fatal(f"indentation does not match any open block at #{this.line}:1")

    editable function close_remaining_blocks() -> void:
        while this.indent_depth > 0z:
            this.indent_depth -= 1
            this.push_token(token.TokenKind.dedent, "", this.line, 1, this.source.len)

    # ── token scanning ──

    editable function scan_token(line_start: ptr_uint) -> void:
        let offset = this.pos
        let b = this.source.byte_at(this.pos)
        this.advance()

        if b == '"':
            this.scan_string(offset, line_start)
        else if b == '\'':
            this.scan_char(offset, line_start)
        else if this.is_alpha(b) or b == '_':
            this.scan_identifier(offset, line_start)
        else if this.is_digit(b):
            this.scan_number(offset, line_start)
        else:
            this.scan_operator(b, offset, line_start)

    editable function scan_string(offset: ptr_uint, line_start: ptr_uint) -> void:
        let col = int<-(offset - line_start) + 1
        let content_start = this.pos
        while this.pos < this.source.len:
            let b = this.source.byte_at(this.pos)
            if b == '"':
                let value = this.source.slice(content_start, this.pos - content_start)
                this.advance()
                let lexeme = this.source.slice(offset, this.pos - offset)
                this.push_token(token.TokenKind.string_literal(value = value), lexeme, this.line, col, offset)
                return
            if b == '\\':
                this.advance()
                if this.pos >= this.source.len:
                    fatal(f"unterminated string literal at #{this.line}:#{col}")
                this.advance()
            else if b == '\n':
                fatal(f"unterminated string literal at #{this.line}:#{col}")
            else:
                this.advance()
        fatal(f"unterminated string literal at #{this.line}:#{col}")

    editable function scan_char(offset: ptr_uint, line_start: ptr_uint) -> void:
        let col = int<-(offset - line_start) + 1
        if this.pos >= this.source.len:
            fatal(f"unterminated character literal at #{this.line}:#{col}")
        var value: ubyte = 0
        let b = this.source.byte_at(this.pos)
        if b == '\\':
            this.advance()
            if this.pos >= this.source.len:
                fatal(f"unterminated escape in character literal at #{this.line}:#{col}")
            let esc = this.source.byte_at(this.pos)
            this.advance()
            if esc == 'x':
                value = this.scan_hex_byte(col)
            else:
                value = this.decode_escape(esc)
        else:
            value = this.source.byte_at(this.pos)
            this.advance()
        if this.pos >= this.source.len or this.source.byte_at(this.pos) != '\'':
            fatal(f"expected closing ' in character literal at #{this.line}:#{col}")
        this.advance()
        let lexeme = this.source.slice(offset, this.pos - offset)
        this.push_token(token.TokenKind.char_literal(value = value), lexeme, this.line, col, offset)

    editable function scan_hex_byte(col: int) -> ubyte:
        if this.pos + 2 > this.source.len:
            fatal(f"invalid hex escape in character literal at #{this.line}:#{col}")
        let high = this.hex_digit_value(this.source.byte_at(this.pos))
        let low = this.hex_digit_value(this.source.byte_at(this.pos + 1))
        this.advance()
        this.advance()
        return (high << 4) | low

    function hex_digit_value(b: ubyte) -> ubyte:
        if b >= '0' and b <= '9':
            return b - '0'
        else if b >= 'A' and b <= 'F':
            return b - 'A' + 10
        else if b >= 'a' and b <= 'f':
            return b - 'a' + 10
        return 0

    editable function scan_identifier(offset: ptr_uint, line_start: ptr_uint) -> void:
        let col = int<-(offset - line_start) + 1
        var p: ptr_uint = this.pos
        while p < this.source.len:
            let b = this.source.byte_at(p)
            if this.is_alpha(b) or this.is_digit(b) or b == '_':
                p += 1
            else:
                break
        let name = this.source.slice(offset, p - offset)
        this.pos = p
        let kind = this.keyword_kind(name)
        this.push_token(kind, name, this.line, col, offset)

    editable function scan_number(offset: ptr_uint, line_start: ptr_uint) -> void:
        let col = int<-(offset - line_start) + 1
        var kind: token.TokenKind = token.TokenKind.int_literal(value = 0)
        var value: int = 0

        if this.pos < this.source.len and this.source.byte_at(offset) == '0':
            let prefix = this.source.byte_at(offset + 1)
            if prefix == 'x' or prefix == 'X':
                this.pos = offset + 2
                value = this.scan_digits(16)
                kind = token.TokenKind.int_literal(value = value)
                let lexeme = this.source.slice(offset, this.pos - offset)
                this.push_token(kind, lexeme, this.line, col, offset)
                return
            else if prefix == 'b' or prefix == 'B':
                this.pos = offset + 2
                value = this.scan_digits(2)
                kind = token.TokenKind.int_literal(value = value)
                let lexeme = this.source.slice(offset, this.pos - offset)
                this.push_token(kind, lexeme, this.line, col, offset)
                return

        this.pos = offset
        value = this.scan_digits(10)
        kind = token.TokenKind.int_literal(value = value)
        let lexeme = this.source.slice(offset, this.pos - offset)
        this.push_token(kind, lexeme, this.line, col, offset)

    editable function scan_digits(base: int) -> int:
        var value: int = 0
        while this.pos < this.source.len:
            let b = this.source.byte_at(this.pos)
            let digit = this.digit_value(b, base)
            if digit < 0:
                break
            value = value * base + digit
            if b == '_':
                this.advance()
            else:
                this.advance()
        return value

    function digit_value(b: ubyte, base: int) -> int:
        if b == '_':
            return 0
        if b >= '0' and b <= '9':
            let d = int<-(b - '0')
            if d < base:
                return d
            return -1
        if base <= 10:
            return -1
        if b >= 'a' and b <= 'f':
            let d = int<-(b - 'a') + 10
            if d < base:
                return d
        if b >= 'A' and b <= 'F':
            let d = int<-(b - 'A') + 10
            if d < base:
                return d
        return -1

    editable function scan_operator(b: ubyte, offset: ptr_uint, line_start: ptr_uint) -> void:
        let col = int<-(offset - line_start) + 1

        if b == '+':
            if this.peek('='):
                this.advance()
                this.push_operator(token.TokenKind.op_plus_assign, "+=", this.line, col, offset)
            else:
                this.push_operator(token.TokenKind.op_plus, "+", this.line, col, offset)
        else if b == '-':
            if this.peek('>'):
                this.advance()
                this.push_operator(token.TokenKind.op_arrow, "->", this.line, col, offset)
            else if this.peek('='):
                this.advance()
                this.push_operator(token.TokenKind.op_minus_assign, "-=", this.line, col, offset)
            else:
                this.push_operator(token.TokenKind.op_minus, "-", this.line, col, offset)
        else if b == '*':
            if this.peek('='):
                this.advance()
                this.push_operator(token.TokenKind.op_star_assign, "*=", this.line, col, offset)
            else:
                this.push_operator(token.TokenKind.op_star, "*", this.line, col, offset)
        else if b == '/':
            if this.peek('='):
                this.advance()
                this.push_operator(token.TokenKind.op_slash_assign, "/=", this.line, col, offset)
            else:
                this.push_operator(token.TokenKind.op_slash, "/", this.line, col, offset)
        else if b == '%':
            if this.peek('='):
                this.advance()
                this.push_operator(token.TokenKind.op_percent_assign, "%=", this.line, col, offset)
            else:
                this.push_operator(token.TokenKind.op_percent, "%", this.line, col, offset)
        else if b == '=':
            if this.peek('='):
                this.advance()
                this.push_operator(token.TokenKind.op_equal, "==", this.line, col, offset)
            else:
                this.push_operator(token.TokenKind.op_assign, "=", this.line, col, offset)
        else if b == '!':
            if this.peek('='):
                this.advance()
                this.push_operator(token.TokenKind.op_not_equal, "!=", this.line, col, offset)
            else:
                fatal(f"unexpected character '!' at #{this.line}:#{col}")
        else if b == '<':
            if this.peek('<'):
                this.advance()
                if this.peek('='):
                    this.advance()
                    this.push_operator(token.TokenKind.op_shift_left_equal, "<<=", this.line, col, offset)
                else:
                    this.push_operator(token.TokenKind.op_shift_left, "<<", this.line, col, offset)
            else if this.peek('='):
                this.advance()
                this.push_operator(token.TokenKind.op_less_equal, "<=", this.line, col, offset)
            else:
                this.push_operator(token.TokenKind.op_less, "<", this.line, col, offset)
        else if b == '>':
            if this.peek('>'):
                this.advance()
                if this.peek('='):
                    this.advance()
                    this.push_operator(token.TokenKind.op_shift_right_equal, ">>=", this.line, col, offset)
                else:
                    this.push_operator(token.TokenKind.op_shift_right, ">>", this.line, col, offset)
            else if this.peek('='):
                this.advance()
                this.push_operator(token.TokenKind.op_greater_equal, ">=", this.line, col, offset)
            else:
                this.push_operator(token.TokenKind.op_greater, ">", this.line, col, offset)
        else if b == '(':
            this.grouping_depth += 1
            if this.grouping_depth == 1z:
                this.grouping_start_line = this.line
            this.push_operator(token.TokenKind.op_lparen, "(", this.line, col, offset)
        else if b == ')':
            if this.grouping_depth > 0z:
                this.grouping_depth -= 1
            this.push_operator(token.TokenKind.op_rparen, ")", this.line, col, offset)
        else if b == '[':
            this.grouping_depth += 1
            if this.grouping_depth == 1z:
                this.grouping_start_line = this.line
            this.push_operator(token.TokenKind.op_lbracket, "[", this.line, col, offset)
        else if b == ']':
            if this.grouping_depth > 0z:
                this.grouping_depth -= 1
            this.push_operator(token.TokenKind.op_rbracket, "]", this.line, col, offset)
        else if b == ',':
            this.push_operator(token.TokenKind.op_comma, ",", this.line, col, offset)
        else if b == ':':
            this.push_operator(token.TokenKind.op_colon, ":", this.line, col, offset)
        else if b == '?':
            this.push_operator(token.TokenKind.op_question, "?", this.line, col, offset)
        else if b == '~':
            this.push_operator(token.TokenKind.op_tilde, "~", this.line, col, offset)
        else if b == '^':
            if this.peek('='):
                this.advance()
                this.push_operator(token.TokenKind.op_caret_equal, "^=", this.line, col, offset)
            else:
                this.push_operator(token.TokenKind.op_caret, "^", this.line, col, offset)
        else if b == '.':
            if this.peek('.'):
                this.advance()
                if this.peek('.'):
                    this.advance()
                    this.push_operator(token.TokenKind.op_ellipsis, "...", this.line, col, offset)
                else:
                    this.push_operator(token.TokenKind.op_dot_dot, "..", this.line, col, offset)
            else:
                this.push_operator(token.TokenKind.op_dot, ".", this.line, col, offset)
        else if b == '&':
            if this.peek('='):
                this.advance()
                this.push_operator(token.TokenKind.op_amp_equal, "&=", this.line, col, offset)
            else:
                this.push_operator(token.TokenKind.op_ampersand, "&", this.line, col, offset)
        else if b == '|':
            if this.peek('='):
                this.advance()
                this.push_operator(token.TokenKind.op_pipe_equal, "|=", this.line, col, offset)
            else:
                this.push_operator(token.TokenKind.op_pipe, "|", this.line, col, offset)
        else if b == '@':
            this.push_operator(token.TokenKind.op_at, "@", this.line, col, offset)
        else:
            fatal(f"unexpected character at #{this.line}:#{col}")

    # ── character classification ──

    function is_alpha(b: ubyte) -> bool:
        return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z')

    function is_digit(b: ubyte) -> bool:
        return b >= '0' and b <= '9'

    function is_alpha_numeric(b: ubyte) -> bool:
        return this.is_alpha(b) or this.is_digit(b)

    # ── helpers ──

    function peek(expected: ubyte) -> bool:
        return this.pos < this.source.len and this.source.byte_at(this.pos) == expected

    editable function advance() -> ubyte:
        let b = this.source.byte_at(this.pos)
        this.pos += 1
        return b

    function decode_escape(b: ubyte) -> ubyte:
        if b == 'n':
            return '\n'
        else if b == 'r':
            return '\r'
        else if b == 't':
            return '\t'
        else if b == '0':
            return '\0'
        else if b == '\'':
            return '\''
        else if b == '"':
            return '"'
        else if b == '\\':
            return '\\'
        return b

    # ── keyword lookup ──

    function keyword_kind(name: str) -> token.TokenKind:
        if name == "function":
            return token.TokenKind.keyword_function
        else if name == "let":
            return token.TokenKind.keyword_let
        else if name == "var":
            return token.TokenKind.keyword_var
        else if name == "return":
            return token.TokenKind.keyword_return
        else if name == "if":
            return token.TokenKind.keyword_if
        else if name == "else":
            return token.TokenKind.keyword_else
        else if name == "for":
            return token.TokenKind.keyword_for
        else if name == "while":
            return token.TokenKind.keyword_while
        else if name == "match":
            return token.TokenKind.keyword_match
        else if name == "break":
            return token.TokenKind.keyword_break
        else if name == "continue":
            return token.TokenKind.keyword_continue
        else if name == "pass":
            return token.TokenKind.keyword_pass
        else if name == "import":
            return token.TokenKind.keyword_import
        else if name == "as":
            return token.TokenKind.keyword_as
        else if name == "public":
            return token.TokenKind.keyword_public
        else if name == "struct":
            return token.TokenKind.keyword_struct
        else if name == "union":
            return token.TokenKind.keyword_union
        else if name == "enum":
            return token.TokenKind.keyword_enum
        else if name == "flags":
            return token.TokenKind.keyword_flags
        else if name == "variant":
            return token.TokenKind.keyword_variant
        else if name == "opaque":
            return token.TokenKind.keyword_opaque
        else if name == "extending":
            return token.TokenKind.keyword_extending
        else if name == "interface":
            return token.TokenKind.keyword_interface
        else if name == "is":
            return token.TokenKind.keyword_is
        else if name == "implements":
            return token.TokenKind.keyword_implements
        else if name == "external":
            return token.TokenKind.keyword_external
        else if name == "foreign":
            return token.TokenKind.keyword_foreign
        else if name == "editable":
            return token.TokenKind.keyword_editable
        else if name == "static":
            return token.TokenKind.keyword_static
        else if name == "fn":
            return token.TokenKind.keyword_fn
        else if name == "in":
            return token.TokenKind.keyword_in
        else if name == "out":
            return token.TokenKind.keyword_out
        else if name == "inout":
            return token.TokenKind.keyword_inout
        else if name == "consuming":
            return token.TokenKind.keyword_consuming
        else if name == "detach":
            return token.TokenKind.keyword_detach
        else if name == "gather":
            return token.TokenKind.keyword_gather
        else if name == "dyn":
            return token.TokenKind.keyword_dyn
        else if name == "proc":
            return token.TokenKind.keyword_proc
        else if name == "link":
            return token.TokenKind.keyword_link
        else if name == "include":
            return token.TokenKind.keyword_include
        else if name == "compiler_flag":
            return token.TokenKind.keyword_compiler_flag
        else if name == "module":
            return token.TokenKind.keyword_module
        else if name == "async":
            return token.TokenKind.keyword_async
        else if name == "const":
            return token.TokenKind.keyword_const
        else if name == "unsafe":
            return token.TokenKind.keyword_unsafe
        else if name == "defer":
            return token.TokenKind.keyword_defer
        else if name == "await":
            return token.TokenKind.keyword_await
        else if name == "type":
            return token.TokenKind.keyword_type
        else if name == "attribute":
            return token.TokenKind.keyword_attribute
        else if name == "event":
            return token.TokenKind.keyword_event
        else if name == "static_assert":
            return token.TokenKind.keyword_static_assert
        else if name == "emit":
            return token.TokenKind.keyword_emit
        else if name == "when":
            return token.TokenKind.keyword_when
        else if name == "inline":
            return token.TokenKind.keyword_inline
        else if name == "parallel":
            return token.TokenKind.keyword_parallel
        else if name == "and":
            return token.TokenKind.keyword_and
        else if name == "or":
            return token.TokenKind.keyword_or
        else if name == "not":
            return token.TokenKind.keyword_not
        else if name == "true":
            return token.TokenKind.keyword_true
        else if name == "false":
            return token.TokenKind.keyword_false
        else if name == "null":
            return token.TokenKind.keyword_null
        else if name == "size_of":
            return token.TokenKind.keyword_size_of
        else if name == "align_of":
            return token.TokenKind.keyword_align_of
        else if name == "offset_of":
            return token.TokenKind.keyword_offset_of
        else if name == "field_of":
            return token.TokenKind.keyword_field_of
        else if name == "fields_of":
            return token.TokenKind.keyword_fields_of
        else if name == "members_of":
            return token.TokenKind.keyword_members_of
        else if name == "callable_of":
            return token.TokenKind.keyword_callable_of
        else if name == "attribute_of":
            return token.TokenKind.keyword_attribute_of
        else if name == "attribute_arg":
            return token.TokenKind.keyword_attribute_arg
        else if name == "attributes_of":
            return token.TokenKind.keyword_attributes_of
        else if name == "has_attribute":
            return token.TokenKind.keyword_has_attribute
        return token.TokenKind.identifier(name = name)

    # ── token constructors ──

    editable function push_operator(
        kind: token.TokenKind,
        lexeme: str,
        line: int,
        column: int,
        offset: ptr_uint,
    ) -> void:
        let tkn = token.Token(kind = kind, lexeme = lexeme, line = line, column = column, start_offset = offset)
        this.tokens.push(tkn)

    editable function push_token(
        kind: token.TokenKind,
        lexeme: str,
        line: int,
        column: int,
        offset: ptr_uint,
    ) -> void:
        let tkn = token.Token(kind = kind, lexeme = lexeme, line = line, column = column, start_offset = offset)
        this.tokens.push(tkn)
