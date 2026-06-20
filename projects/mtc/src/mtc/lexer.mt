# Lexer for the self-hosting Milk Tea compiler.

import mtc.token
import std.str
import std.vec

struct Lexer:
    source: str
    pos: ptr_uint
    line: int
    column: int
    tokens: vec.Vec[token.Token]

extending Lexer:
    public static function from_source(source: str) -> Lexer:
        return Lexer(
            source = source,
            pos = 0z,
            line = 1,
            column = 1,
            tokens = vec.Vec[token.Token].create()
        )

    public editable function tokenize() -> void:
        while not this.at_end():
            this.skip_whitespace()
            if this.at_end():
                break
            this.scan_token()

    public function at_end() -> bool:
        return this.pos >= this.source.len

    function current_byte() -> ubyte:
        return this.source.byte_at(this.pos)

    function peek_byte(offset: ptr_uint) -> ubyte:
        let idx = this.pos + offset
        if idx < this.source.len:
            return this.source.byte_at(idx)
        return 0

    editable function advance() -> ubyte:
        let b = this.current_byte()
        this.pos += 1
        if b == '\n':
            this.line += 1
            this.column = 1
        else:
            this.column += 1
        return b

    editable function skip_whitespace() -> void:
        while not this.at_end():
            let b = this.current_byte()
            if b == ' ' or b == '\t' or b == '\r':
                this.advance()
            else if b == '\n':
                this.advance()
            else if b == '#':
                this.skip_line_comment()
            else:
                return

    editable function skip_line_comment() -> void:
        while not this.at_end() and this.current_byte() != '\n':
            this.advance()

    editable function scan_token() -> void:
        let line = this.line
        let col = this.column
        let b = this.advance()
        var kind: token.TokenKind = token.TokenKind.eof

        if b == '+':
            kind = token.TokenKind.op_plus
        else if b == '-':
            if this.current_byte() == '>':
                this.advance()
                kind = token.TokenKind.op_arrow
            else:
                kind = token.TokenKind.op_minus
        else if b == '*':
            kind = token.TokenKind.op_star
        else if b == '/':
            kind = token.TokenKind.op_slash
        else if b == '%':
            kind = token.TokenKind.op_percent
        else if b == '=':
            if this.current_byte() == '=':
                this.advance()
                kind = token.TokenKind.op_equal
            else:
                kind = token.TokenKind.op_assign
        else if b == '!':
            if this.current_byte() == '=':
                this.advance()
                kind = token.TokenKind.op_not_equal
            else:
                this.fatal_error(line, col, "unexpected character '!'")
        else if b == '<':
            if this.current_byte() == '=':
                this.advance()
                kind = token.TokenKind.op_less_equal
            else if this.current_byte() == '<':
                this.advance()
                kind = token.TokenKind.op_shift_left
            else:
                kind = token.TokenKind.op_less
        else if b == '>':
            if this.current_byte() == '=':
                this.advance()
                kind = token.TokenKind.op_greater_equal
            else if this.current_byte() == '>':
                this.advance()
                kind = token.TokenKind.op_shift_right
            else:
                kind = token.TokenKind.op_greater
        else if b == '(':
            kind = token.TokenKind.op_lparen
        else if b == ')':
            kind = token.TokenKind.op_rparen
        else if b == '[':
            kind = token.TokenKind.op_lbracket
        else if b == ']':
            kind = token.TokenKind.op_rbracket
        else if b == ',':
            kind = token.TokenKind.op_comma
        else if b == ':':
            kind = token.TokenKind.op_colon
        else if b == ';':
            kind = token.TokenKind.op_semicolon
        else if b == '?':
            kind = token.TokenKind.op_question
        else if b == '~':
            kind = token.TokenKind.op_tilde
        else if b == '^':
            kind = token.TokenKind.op_caret
        else if b == '.':
            kind = token.TokenKind.op_dot
        else if b == '#':
            kind = token.TokenKind.op_hash
        else if b == '&':
            kind = token.TokenKind.op_ampersand
        else if b == '|':
            kind = token.TokenKind.op_pipe
        else if b == '\"':
            kind = this.scan_string()
        else if this.is_alpha(b) or b == '_':
            kind = this.scan_identifier_or_keyword()
        else if this.is_digit(b):
            kind = this.scan_number()
        else:
            this.fatal_error(line, col, f"unexpected character")

        var length_val = int<-(this.column - col)
        if length_val < 1:
            length_val = 1
        this.tokens.push(token.Token(kind = kind, line = line, column = col, length = length_val))

    function is_alpha(b: ubyte) -> bool:
        return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z')

    function is_digit(b: ubyte) -> bool:
        return b >= '0' and b <= '9'

    editable function scan_string() -> token.TokenKind:
        let start = this.pos
        while not this.at_end() and this.current_byte() != '\"':
            if this.current_byte() == '\\':
                this.advance()
            this.advance()
        if this.at_end():
            this.fatal_error(this.line, this.column, "unterminated string literal")
        this.advance()
        let end_pos = this.pos
        if end_pos > start:
            return token.TokenKind.string_literal(value = this.source.slice(start, end_pos - start))
        return token.TokenKind.string_literal(value = "")

    editable function scan_identifier_or_keyword() -> token.TokenKind:
        let start = this.pos - 1
        while not this.at_end():
            let b = this.current_byte()
            if this.is_alpha(b) or this.is_digit(b) or b == '_':
                this.advance()
            else:
                break
        let end_pos = this.pos
        var name: str = ""
        if end_pos > start:
            name = this.source.slice(start, end_pos - start)
        return this.keyword(name)

    function keyword(name: str) -> token.TokenKind:
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
        else if name == "implements":
            return token.TokenKind.keyword_implements
        else if name == "external":
            return token.TokenKind.keyword_external
        else if name == "foreign":
            return token.TokenKind.keyword_foreign
        else if name == "async":
            return token.TokenKind.keyword_function_async
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
        return token.TokenKind.identifier(name = name)

    editable function scan_number() -> token.TokenKind:
        var value: int = 0
        this.pos -= 1
        while not this.at_end():
            let b = this.current_byte()
            if this.is_digit(b):
                value = value * 10 + int<-(b - '0')
                this.advance()
            else:
                break
        return token.TokenKind.int_literal(value = value)

    function fatal_error(line: int, col: int, msg: str) -> void:
        fatal(f"lexer error at {line}:{col}: {msg}")

    public function finish() -> vec.Vec[token.Token]:
        return this.tokens
