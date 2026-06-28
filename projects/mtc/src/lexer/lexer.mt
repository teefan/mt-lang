import std.str
import std.vec as vec

import lexer.token as tok

const INDENT_SPACES: ptr_uint = 4

public struct Lexer:
    source: str
    file_id: uint
    offset: ptr_uint
    line_start: ptr_uint
    indent_stack: vec.Vec[ptr_uint]
    grouping_depth: uint
    continuation_pending: bool

extending Lexer:
    public static function create(source: str, file_id: uint) -> Lexer:
        return Lexer(
            source = source,
            file_id = file_id,
            offset = 0,
            line_start = 0,
            indent_stack = vec.Vec[ptr_uint].create(),
            grouping_depth = 0,
            continuation_pending = false
        )

    public editable function lex() -> vec.Vec[tok.Token]:
        var tokens = vec.Vec[tok.Token].create()
        this.indent_stack.push(0)

        while this.offset < this.source.len:
            if not this.continuation_pending and this.grouping_depth == 0:
                let col = this.offset - this.line_start
                if col == 0:
                    let indent = this.read_indent()
                    if indent > 0:
                        this.emit_indents(indent, ref_of(tokens))
                        if this.offset >= this.source.len:
                            break
                    else:
                        if this.offset >= this.source.len:
                            break

            this.lex_token(ref_of(tokens))

        while this.indent_stack.len() > 1:
            let _level = this.indent_stack.pop()
            tokens.push(this.make_newline_token(this.offset))

        tokens.push(this.make_token(tok.TokenKind.eof, this.offset, this.offset, ""))
        return tokens

    function make_newline_token(offset: ptr_uint) -> tok.Token:
        return tok.Token(
            kind = tok.TokenKind.newline,
            file_id = this.file_id,
            offset = offset,
            lexeme = "",
            keyword_subkind = 0
        )

    function make_token(kind: tok.TokenKind, start: ptr_uint, end: ptr_uint, lexeme: str) -> tok.Token:
        let _ = end
        return tok.Token(kind = kind, file_id = this.file_id, offset = start, lexeme = lexeme, keyword_subkind = 0)

    function make_keyword(kind: tok.KeywordKind, start: ptr_uint, end: ptr_uint, lexeme: str) -> tok.Token:
        let _ = end
        return tok.Token(
            kind = tok.TokenKind.keyword,
            file_id = this.file_id,
            offset = start,
            lexeme = lexeme,
            keyword_subkind = uint<-(kind)
        )

    function peek(adv: ptr_uint) -> ubyte:
        let idx = this.offset + adv
        if idx >= this.source.len:
            return 0
        return this.source.byte_at(idx)

    function current() -> ubyte:
        return this.peek(0)

    editable function advance_byte() -> void:
        this.offset += 1

    function is_ident_start(ch: ubyte) -> bool:
        return ch >= 'a' and ch <= 'z' or ch >= 'A' and ch <= 'Z' or ch == '_'

    function is_ident_cont(ch: ubyte) -> bool:
        return this.is_ident_start(ch) or ch >= '0' and ch <= '9'

    function is_digit(ch: ubyte) -> bool:
        return ch >= '0' and ch <= '9'

    function is_hex_digit(ch: ubyte) -> bool:
        return this.is_digit(ch) or ch >= 'a' and ch <= 'f' or ch >= 'A' and ch <= 'F'

    editable function read_indent() -> ptr_uint:
        var col: ptr_uint = 0
        var idx = this.offset
        while idx < this.source.len and this.source.byte_at(idx) == ' ':
            idx += 1
            col += 1

        if idx >= this.source.len:
            this.offset = idx
            return 0

        if this.source.byte_at(idx) == '\n':
            this.offset = idx + 1
            this.line_start = this.offset
            return 0

        if this.source.byte_at(idx) == '\r':
            this.offset = idx + 1
            if this.offset < this.source.len and this.source.byte_at(this.offset) == '\n':
                this.offset += 1
            this.line_start = this.offset
            return 0

        if this.source.byte_at(idx) == '#':
            return col

        if this.source.byte_at(idx) == '\t':
            fatal(c"tab character in source")

        this.offset = idx
        return col

    editable function emit_indents(indent: ptr_uint, tokens: ref[vec.Vec[tok.Token]]) -> void:
        let current = this.current_indent()

        if indent > current:
            if indent != current + INDENT_SPACES:
                fatal(c"indentation must increase by 4 spaces")
            this.indent_stack.push(indent)
            tokens.push(this.make_token(tok.TokenKind.indent, this.offset, this.offset, ""))

        else if indent < current:
            while this.indent_stack.len() > 1 and this.current_indent() > indent:
                let _level = this.indent_stack.pop()
                tokens.push(this.make_token(tok.TokenKind.dedent, this.offset, this.offset, ""))
            if this.current_indent() != indent:
                fatal(c"indentation does not match any outer level")

    function current_indent() -> ptr_uint:
        let last_ptr = this.indent_stack.last() else:
            return 0
        unsafe:
            return read(last_ptr)

    editable function lex_token(tokens: ref[vec.Vec[tok.Token]]) -> void:
        let ch = this.current()

        if this.is_ident_start(ch):
            this.lex_identifier(tokens)
            return

        if this.is_digit(ch):
            this.lex_number(tokens)
            return

        if ch == '"':
            this.lex_quoted_string(tokens, false)
            return

        if ch == '\'':
            this.lex_char_literal(tokens)
            return

        if ch == '#':
            this.skip_comment()
            return

        if ch == '\n':
            this.advance_byte()
            this.line_start = this.offset
            if this.grouping_depth == 0 and not this.continuation_pending:
                tokens.push(this.make_newline_token(this.offset))
            this.continuation_pending = false
            return

        if ch == '\r':
            this.advance_byte()
            if this.current() == '\n':
                this.advance_byte()
            this.line_start = this.offset
            if this.grouping_depth == 0 and not this.continuation_pending:
                tokens.push(this.make_newline_token(this.offset))
            this.continuation_pending = false
            return

        if ch == ' ':
            this.advance_byte()
            return

        if ch == 'c':
            this.advance_byte()
            if this.current() == '"':
                this.lex_quoted_string(tokens, true)
                return
            tokens.push(this.make_token(tok.TokenKind.identifier, this.offset - 1, this.offset, "c"))
            return

        this.lex_operator(tokens)

    editable function lex_identifier(tokens: ref[vec.Vec[tok.Token]]) -> void:
        let start = this.offset
        this.advance_byte()

        while this.offset < this.source.len and this.is_ident_cont(this.current()):
            this.advance_byte()

        let end = this.offset
        let lexeme = this.source.slice(start, end - start)

        let kw = lookup_keyword(lexeme)
        match kw:
            Option.none:
                tokens.push(this.make_token(tok.TokenKind.identifier, start, end, lexeme))
            Option.some as k:
                tokens.push(this.make_keyword(k.value, start, end, lexeme))

    editable function lex_number(tokens: ref[vec.Vec[tok.Token]]) -> void:
        let start = this.offset

        if this.current() == '0' and this.peek(1) == 'x':
            this.advance_byte()
            this.advance_byte()
            while this.offset < this.source.len and this.is_hex_digit(this.current()):
                this.advance_byte()

        else if this.current() == '0' and this.peek(1) == 'b':
            this.advance_byte()
            this.advance_byte()
            this.lex_while_digit_or('_')

        else:
            this.lex_while_digit_or('_')

        if this.current() == '.' and this.peek(1) >= '0' and this.peek(1) <= '9':
            this.advance_byte()
            this.lex_while_digit_or('_')
            this.lex_float_suffix(tokens, start)
            return

        if this.current() == 'e' or this.current() == 'E':
            this.advance_byte()
            if this.current() == '+' or this.current() == '-':
                this.advance_byte()
            this.lex_while_digit_or('_')
            this.lex_float_suffix(tokens, start)
            return

        this.lex_integer_suffix(tokens, start)

    editable function lex_float_suffix(tokens: ref[vec.Vec[tok.Token]], start: ptr_uint) -> void:
        if this.current() == 'f' or this.current() == 'd':
            this.advance_byte()
        let end = this.offset
        tokens.push(this.make_token(tok.TokenKind.float_literal, start, end, this.source.slice(start, end - start)))

    editable function lex_integer_suffix(tokens: ref[vec.Vec[tok.Token]], start: ptr_uint) -> void:
        let ch = this.current()
        if ch == 'u' or ch == 'i' or ch == 'z' or ch == 'l' or ch == 'b':
            this.advance_byte()
        let end = this.offset
        tokens.push(this.make_token(tok.TokenKind.integer_literal, start, end, this.source.slice(start, end - start)))

    editable function lex_while_digit_or(extra: ubyte) -> void:
        while this.offset < this.source.len:
            let ch = this.current()
            if this.is_digit(ch) or ch == extra:
                this.advance_byte()
            else:
                break

    editable function lex_quoted_string(tokens: ref[vec.Vec[tok.Token]], is_cstring: bool) -> void:
        let start = this.offset
        this.advance_byte()

        while this.offset < this.source.len:
            let ch = this.current()
            if ch == '\\':
                this.advance_byte()
                if this.offset < this.source.len:
                    this.advance_byte()
            else if ch == '"':
                this.advance_byte()
                let end = this.offset
                let kind = if is_cstring: tok.TokenKind.cstring_literal else: tok.TokenKind.string_literal
                tokens.push(this.make_token(kind, start, end, this.source.slice(start, end - start)))
                return
            else if ch == '\n':
                let end = this.offset
                let kind = if is_cstring: tok.TokenKind.cstring_literal else: tok.TokenKind.string_literal
                tokens.push(this.make_token(kind, start, end, this.source.slice(start, end - start)))
                return
            else:
                this.advance_byte()

        let end = this.offset
        let kind = if is_cstring: tok.TokenKind.cstring_literal else: tok.TokenKind.string_literal
        tokens.push(this.make_token(kind, start, end, this.source.slice(start, end - start)))

    editable function lex_char_literal(tokens: ref[vec.Vec[tok.Token]]) -> void:
        let start = this.offset
        this.advance_byte()

        while this.offset < this.source.len:
            let ch = this.current()
            if ch == '\\':
                this.advance_byte()
                if this.offset < this.source.len:
                    this.advance_byte()
            else if ch == '\'':
                this.advance_byte()
                let end = this.offset
                let lit = this.source.slice(start, end - start)
                tokens.push(this.make_token(tok.TokenKind.char_literal, start, end, lit))
                return
            else if ch == '\n':
                let end = this.offset
                let lit = this.source.slice(start, end - start)
                tokens.push(this.make_token(tok.TokenKind.char_literal, start, end, lit))
                return
            else:
                this.advance_byte()

        let end = this.offset
        let lit = this.source.slice(start, end - start)
        tokens.push(this.make_token(tok.TokenKind.char_literal, start, end, lit))

    editable function skip_comment() -> void:
        while this.offset < this.source.len and this.current() != '\n' and this.current() != '\r':
            this.advance_byte()

    editable function lex_operator(tokens: ref[vec.Vec[tok.Token]]) -> void:
        let start = this.offset
        let ch = this.current()
        let nxt = this.peek(1)

        if ch == ':':
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.colon, start, this.offset, ":"))
            return

        if ch == '-' and nxt == '>':
            this.advance_byte()
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.arrow, start, this.offset, "->"))
            return

        if ch == ',':
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.comma, start, this.offset, ","))
            return

        if ch == '.':
            if nxt == '.' and this.peek(2) == '.':
                this.advance_byte()
                this.advance_byte()
                this.advance_byte()
                tokens.push(this.make_token(tok.TokenKind.ellipsis, start, this.offset, "..."))
                return
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.dot, start, this.offset, "."))
            return

        if ch == '?':
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.question_mark, start, this.offset, "?"))
            return

        if ch == '@':
            this.advance_byte()
            if this.current() == '[':
                this.advance_byte()
                tokens.push(this.make_token(tok.TokenKind.attr_open, start, this.offset, "@["))
                return
            tokens.push(this.make_token(tok.TokenKind.error, start, this.offset, ""))
            return

        if ch == ']':
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.bracket_close, start, this.offset, "]"))
            return

        if ch == '(':
            this.advance_byte()
            this.grouping_depth += 1
            tokens.push(this.make_token(tok.TokenKind.paren_open, start, this.offset, "("))
            return

        if ch == ')':
            this.advance_byte()
            if this.grouping_depth > 0:
                this.grouping_depth -= 1
            tokens.push(this.make_token(tok.TokenKind.paren_close, start, this.offset, ")"))
            return

        if ch == '[':
            this.advance_byte()
            this.grouping_depth += 1
            tokens.push(this.make_token(tok.TokenKind.bracket_open, start, this.offset, "["))
            return

        if ch == '=' and nxt == '=':
            this.advance_byte()
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_eq, start, this.offset, "=="))
            this.continuation_pending = true
            return

        if ch == '!' and nxt == '=':
            this.advance_byte()
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_ne, start, this.offset, "!="))
            this.continuation_pending = true
            return

        if ch == '<' and nxt == '=':
            this.advance_byte()
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_le, start, this.offset, "<="))
            this.continuation_pending = true
            return

        if ch == '>' and nxt == '=':
            this.advance_byte()
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_ge, start, this.offset, ">="))
            this.continuation_pending = true
            return

        if ch == '<' and nxt == '<':
            this.advance_byte()
            this.advance_byte()
            if this.current() == '=':
                this.advance_byte()
                tokens.push(this.make_token(tok.TokenKind.op_shl, start, this.offset, "<<="))
                return
            tokens.push(this.make_token(tok.TokenKind.op_shl, start, this.offset, "<<"))
            this.continuation_pending = true
            return

        if ch == '>' and nxt == '>':
            this.advance_byte()
            this.advance_byte()
            if this.current() == '=':
                this.advance_byte()
                tokens.push(this.make_token(tok.TokenKind.op_shr, start, this.offset, ">>="))
                return
            tokens.push(this.make_token(tok.TokenKind.op_shr, start, this.offset, ">>"))
            this.continuation_pending = true
            return

        if ch == '+' and nxt == '=':
            this.advance_byte()
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_add, start, this.offset, "+="))
            return

        if ch == '-' and nxt == '=':
            this.advance_byte()
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_sub, start, this.offset, "-="))
            return

        if ch == '*' and nxt == '=':
            this.advance_byte()
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_mul, start, this.offset, "*="))
            return

        if ch == '/' and nxt == '=':
            this.advance_byte()
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_div, start, this.offset, "/="))
            return

        if ch == '%' and nxt == '=':
            this.advance_byte()
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_mod, start, this.offset, "%="))
            return

        if ch == '&' and nxt == '=':
            this.advance_byte()
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_bit_and, start, this.offset, "&="))
            return

        if ch == '|' and nxt == '=':
            this.advance_byte()
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_bit_or, start, this.offset, "|="))
            return

        if ch == '^' and nxt == '=':
            this.advance_byte()
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_bit_xor, start, this.offset, "^="))
            return

        if ch == '=':
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_assign, start, this.offset, "="))
            return

        if ch == '+':
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_add, start, this.offset, "+"))
            this.continuation_pending = true
            return

        if ch == '-':
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_sub, start, this.offset, "-"))
            this.continuation_pending = true
            return

        if ch == '*':
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_mul, start, this.offset, "*"))
            this.continuation_pending = true
            return

        if ch == '/':
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_div, start, this.offset, "/"))
            this.continuation_pending = true
            return

        if ch == '%':
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_mod, start, this.offset, "%"))
            this.continuation_pending = true
            return

        if ch == '<':
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_lt, start, this.offset, "<"))
            this.continuation_pending = true
            return

        if ch == '>':
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_gt, start, this.offset, ">"))
            this.continuation_pending = true
            return

        if ch == '&':
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_bit_and, start, this.offset, "&"))
            this.continuation_pending = true
            return

        if ch == '|':
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_bit_or, start, this.offset, "|"))
            this.continuation_pending = true
            return

        if ch == '^':
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_bit_xor, start, this.offset, "^"))
            this.continuation_pending = true
            return

        if ch == '~':
            this.advance_byte()
            tokens.push(this.make_token(tok.TokenKind.op_bit_not, start, this.offset, "~"))
            return

        this.advance_byte()
        tokens.push(this.make_token(tok.TokenKind.error, start, this.offset, ""))

public function lookup_keyword(text: str) -> Option[tok.KeywordKind]:
    match text:
        "function":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_function)
        "struct":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_struct)
        "enum":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_enum)
        "flags":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_flags)
        "union":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_union)
        "variant":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_variant)
        "interface":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_interface)
        "extending":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_extending)
        "opaque":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_opaque)
        "const":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_const)
        "var":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_var)
        "let":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_let)
        "type":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_type)
        "if":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_if)
        "else":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_else)
        "while":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_while)
        "for":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_for)
        "match":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_match)
        "return":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_return)
        "break":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_break)
        "continue":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_continue)
        "pass":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_pass)
        "defer":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_defer)
        "unsafe":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_unsafe)
        "inline":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_inline)
        "when":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_when)
        "emit":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_emit)
        "static_assert":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_static_assert)
        "import":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_import)
        "public":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_public)
        "external":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_external)
        "foreign":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_foreign)
        "async":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_async)
        "await":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_await)
        "and":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_and)
        "or":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_or)
        "not":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_not)
        "is":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_is)
        "in":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_in)
        "out":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_out)
        "inout":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_inout)
        "as":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_as)
        "else if":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_else_if)
        "ref":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_ref)
        "ptr":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_ptr)
        "span":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_span)
        "array":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_array)
        "attribute":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_attribute)
        "event":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_event)
        "parallel":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_parallel)
        "detach":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_detach)
        "gather":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_gather)
        "do":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_do)
        "implements":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_implements)
        "size_of":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_size_of)
        "align_of":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_align_of)
        "offset_of":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_offset_of)
        "consuming":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_consuming)
        "editable":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_editable)
        "static":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_static)
        "null":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_null)
        "true":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_true)
        "false":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_false)
        "with":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_with)
        "adapt":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_adapt)
        "dyn":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_dyn)
        "proc":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_proc)
        "fn":
            return Option[tok.KeywordKind].some(value = tok.KeywordKind.kw_fn)
        _:
            return Option[tok.KeywordKind].none
