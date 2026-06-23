## Lexer — Milk Tea source text → Vec[Token].
##
## Handles: identifiers/keywords, integers/floats, strings/cstrings,
## char literals, format strings (basic), operators/delimiters,
## comments (skip), newlines, indentation tracking, EOF.

import compiler.lexer.cursor as cursor_mod
import compiler.lexer.token as token_mod
import compiler.lexer.token_kind as tk
import std.intern
import std.map
import std.vec

type T = tk.TokenKind

struct Lexer:
    cursor: cursor_mod.Cursor
    tokens: vec.Vec[token_mod.Token]
    kw_map: map.Map[ptr_uint, T]
    indent_stack: vec.Vec[ptr_uint]
    grouping_depth: ptr_uint
    continuation_pending: bool


public function lex(
    source: span[ubyte],
    interner_ref: ref[intern.Interner],
) -> vec.Vec[token_mod.Token]:
    var lexer = Lexer(
        cursor = cursor_mod.create(source),
        tokens = vec.Vec[token_mod.Token].create(),
        kw_map = map.Map[ptr_uint, T].with_capacity(64),
        indent_stack = vec.Vec[ptr_uint].create(),
        grouping_depth = 0,
        continuation_pending = false,
    )
    lexer.indent_stack.push(0)
    lexer.build_keyword_map(interner_ref)
    lexer.lex_tokens(interner_ref)
    lexer.finish()
    return lexer.tokens


extending Lexer:
    ## ── keyword map ─────────────────────────────────────────────

    editable function build_keyword_map(
        interner_ref: ref[intern.Interner],
    ) -> void:
        this.add_kw("align_of", T.tk_kw_align_of, interner_ref)
        this.add_kw("and", T.tk_kw_and, interner_ref)
        this.add_kw("as", T.tk_kw_as, interner_ref)
        this.add_kw("async", T.tk_kw_async, interner_ref)
        this.add_kw("attribute", T.tk_kw_attribute, interner_ref)
        this.add_kw("attribute_arg", T.tk_kw_attribute_arg, interner_ref)
        this.add_kw("attribute_of", T.tk_kw_attribute_of, interner_ref)
        this.add_kw("attributes_of", T.tk_kw_attributes_of, interner_ref)
        this.add_kw("await", T.tk_kw_await, interner_ref)
        this.add_kw("break", T.tk_kw_break, interner_ref)
        this.add_kw("callable_of", T.tk_kw_callable_of, interner_ref)
        this.add_kw("compiler_flag", T.tk_kw_compiler_flag, interner_ref)
        this.add_kw("const", T.tk_kw_const, interner_ref)
        this.add_kw("consuming", T.tk_kw_consuming, interner_ref)
        this.add_kw("continue", T.tk_kw_continue, interner_ref)
        this.add_kw("defer", T.tk_kw_defer, interner_ref)
        this.add_kw("detach", T.tk_kw_detach, interner_ref)
        this.add_kw("dyn", T.tk_kw_dyn, interner_ref)
        this.add_kw("editable", T.tk_kw_editable, interner_ref)
        this.add_kw("else", T.tk_kw_else, interner_ref)
        this.add_kw("emit", T.tk_kw_emit, interner_ref)
        this.add_kw("enum", T.tk_kw_enum, interner_ref)
        this.add_kw("event", T.tk_kw_event, interner_ref)
        this.add_kw("extending", T.tk_kw_extending, interner_ref)
        this.add_kw("external", T.tk_kw_external, interner_ref)
        this.add_kw("false", T.tk_kw_false, interner_ref)
        this.add_kw("field_of", T.tk_kw_field_of, interner_ref)
        this.add_kw("fields_of", T.tk_kw_fields_of, interner_ref)
        this.add_kw("flags", T.tk_kw_flags, interner_ref)
        this.add_kw("fn", T.tk_kw_fn, interner_ref)
        this.add_kw("for", T.tk_kw_for, interner_ref)
        this.add_kw("foreign", T.tk_kw_foreign, interner_ref)
        this.add_kw("function", T.tk_kw_function, interner_ref)
        this.add_kw("gather", T.tk_kw_gather, interner_ref)
        this.add_kw("has_attribute", T.tk_kw_has_attribute, interner_ref)
        this.add_kw("if", T.tk_kw_if, interner_ref)
        this.add_kw("implements", T.tk_kw_implements, interner_ref)
        this.add_kw("import", T.tk_kw_import, interner_ref)
        this.add_kw("in", T.tk_kw_in, interner_ref)
        this.add_kw("inline", T.tk_kw_inline, interner_ref)
        this.add_kw("inout", T.tk_kw_inout, interner_ref)
        this.add_kw("interface", T.tk_kw_interface, interner_ref)
        this.add_kw("is", T.tk_kw_is, interner_ref)
        this.add_kw("let", T.tk_kw_let, interner_ref)
        this.add_kw("link", T.tk_kw_link, interner_ref)
        this.add_kw("match", T.tk_kw_match, interner_ref)
        this.add_kw("members_of", T.tk_kw_members_of, interner_ref)
        this.add_kw("module", T.tk_kw_module, interner_ref)
        this.add_kw("not", T.tk_kw_not, interner_ref)
        this.add_kw("null", T.tk_kw_null, interner_ref)
        this.add_kw("offset_of", T.tk_kw_offset_of, interner_ref)
        this.add_kw("opaque", T.tk_kw_opaque, interner_ref)
        this.add_kw("or", T.tk_kw_or, interner_ref)
        this.add_kw("out", T.tk_kw_out, interner_ref)
        this.add_kw("parallel", T.tk_kw_parallel, interner_ref)
        this.add_kw("pass", T.tk_kw_pass, interner_ref)
        this.add_kw("proc", T.tk_kw_proc, interner_ref)
        this.add_kw("public", T.tk_kw_public, interner_ref)
        this.add_kw("return", T.tk_kw_return, interner_ref)
        this.add_kw("size_of", T.tk_kw_size_of, interner_ref)
        this.add_kw("static", T.tk_kw_static, interner_ref)
        this.add_kw("static_assert", T.tk_kw_static_assert, interner_ref)
        this.add_kw("struct", T.tk_kw_struct, interner_ref)
        this.add_kw("type", T.tk_kw_type, interner_ref)
        this.add_kw("union", T.tk_kw_union, interner_ref)
        this.add_kw("unsafe", T.tk_kw_unsafe, interner_ref)
        this.add_kw("var", T.tk_kw_var, interner_ref)
        this.add_kw("variant", T.tk_kw_variant, interner_ref)
        this.add_kw("when", T.tk_kw_when, interner_ref)
        this.add_kw("while", T.tk_kw_while, interner_ref)


    editable function add_kw(
        text: str,
        kind: T,
        interner_ref: ref[intern.Interner],
    ) -> void:
        let id = interner_ref.intern(text)
        let _ = this.kw_map.set(id, kind)


    ## ── token helpers ────────────────────────────────────────────

    editable function push_token(
        kind: T,
        start: ptr_uint,
        end: ptr_uint,
        line: ptr_uint,
        col: ptr_uint,
    ) -> void:
        let token = token_mod.create_symbol(kind, start, end, line, col)
        this.tokens.push(token)


    editable function push_ident_token(
        kind: T,
        start: ptr_uint,
        end: ptr_uint,
        line: ptr_uint,
        col: ptr_uint,
        ident: ptr_uint,
    ) -> void:
        let token = token_mod.create_ident(kind, start, end, line, col, ident)
        this.tokens.push(token)


    ## ── main lexing loop ─────────────────────────────────────────

    editable function lex_tokens(
        interner_ref: ref[intern.Interner],
    ) -> void:
        while not this.cursor.at_end():
            let start_pos = this.cursor.pos
            let line = this.cursor.line
            let col = this.cursor.col
            let ch = this.cursor.current()

            if token_mod.is_space(ch):
                this.cursor.advance()
                continue

            if token_mod.is_newline(ch):
                this.cursor.advance()
                this.push_token(T.tk_newline, start_pos, this.cursor.pos, line, col)
                this.handle_indent()
                continue

            if token_mod.is_ident_start(ch):
                this.lex_identifier(start_pos, line, col, interner_ref)
                continue

            if token_mod.is_digit(ch):
                this.lex_number(start_pos, line, col)
                continue

            if ch == '"':
                this.lex_string(start_pos, line, col, false)
                continue

            if ch == '\'':
                this.lex_char_literal(start_pos, line, col)
                continue

            if ch == '#' and this.cursor.peek(1).unwrap() == '#':
                this.skip_line_comment()
                continue

            if ch == '#':
                this.skip_line_comment()
                continue

            if ch == 'c' and this.cursor.peek(1).unwrap() == '"':
                this.cursor.advance()
                this.lex_string(start_pos, line, col, true)
                continue

            if ch == 'f' and this.cursor.peek(1).unwrap() == '"':
                this.cursor.advance()
                this.lex_format_string(start_pos, line, col)
                continue

            this.lex_operator(start_pos, line, col)


    ## ── identifier / keyword ─────────────────────────────────────

    editable function lex_identifier(
        start: ptr_uint,
        line: ptr_uint,
        col: ptr_uint,
        interner_ref: ref[intern.Interner],
    ) -> void:
        var len: ptr_uint = 0
        while not this.cursor.at_end() and token_mod.is_ident_part(this.cursor.current()):
            this.cursor.advance()
            len += 1

        let end_pos = this.cursor.pos
        let text = this.cursor.slice_from(start, len)
        let ident = interner_ref.intern(text)
        let kind = this.resolve_keyword(ident)
        this.push_ident_token(kind, start, end_pos, line, col, ident)


    function resolve_keyword(ident: ptr_uint) -> T:
        let found = this.kw_map.get(ident) else:
            return T.tk_identifier

        unsafe:
            return read(found)


    ## ── number literals ──────────────────────────────────────────

    editable function lex_number(
        start: ptr_uint,
        line: ptr_uint,
        col: ptr_uint,
    ) -> void:
        var is_float = false

        if this.cursor.current() == '0':
            let next = this.cursor.peek(1).unwrap()
            if next == 'x' or next == 'X' or next == 'b' or next == 'B':
                this.cursor.advance_by(2)
                while not this.cursor.at_end() and token_mod.is_hex_digit_or_uscore(this.cursor.current()):
                    this.cursor.advance()
                this.push_token(T.tk_integer, start, this.cursor.pos, line, col)
                return

        while not this.cursor.at_end() and token_mod.is_digit_or_uscore(this.cursor.current()):
            this.cursor.advance()

        if not this.cursor.at_end() and this.cursor.current() == '.':
            let next_ch = this.cursor.peek(1).unwrap()
            if token_mod.is_digit(next_ch):
                is_float = true
                this.cursor.advance()
                while not this.cursor.at_end() and token_mod.is_digit_or_uscore(this.cursor.current()):
                    this.cursor.advance()

        if not this.cursor.at_end():
            let exp = this.cursor.current()
            if exp == 'e' or exp == 'E':
                let next = this.cursor.peek(1).unwrap()
                if token_mod.is_digit(next) or next == '+' or next == '-':
                    is_float = true
                    this.cursor.advance()
                    if this.cursor.current() == '+' or this.cursor.current() == '-':
                        this.cursor.advance()
                    while not this.cursor.at_end() and token_mod.is_digit(this.cursor.current()):
                        this.cursor.advance()

        this.skip_int_suffix()
        this.skip_float_suffix(is_float)

        let kind = if is_float: T.tk_float else: T.tk_integer
        this.push_token(kind, start, this.cursor.pos, line, col)


    editable function skip_int_suffix() -> void:
        if this.cursor.at_end():
            return

        let ch = this.cursor.current()
        if not token_mod.is_alpha(ch) and ch != '_':
            return

        let pos_before = this.cursor.pos
        while not this.cursor.at_end() and (token_mod.is_alnum(this.cursor.current()) or this.cursor.current() == '_'):
            this.cursor.advance()

        let pos_after = this.cursor.pos
        if pos_after > pos_before + 2:
            this.cursor.pos = pos_before
        else if pos_after > pos_before:
            # check next char is not alphanumeric (suffix boundary)
            if not this.cursor.at_end() and token_mod.is_alnum(this.cursor.current()):
                this.cursor.pos = pos_before


    editable function skip_float_suffix(is_float: bool) -> void:
        if not is_float:
            return
        if this.cursor.at_end():
            return

        let ch = this.cursor.current()
        if ch == 'f' or ch == 'd':
            let next = this.cursor.peek(1) else:
                return
            if not token_mod.is_alnum(next):
                this.cursor.advance()


    ## ── string / cstring ─────────────────────────────────────────

    editable function lex_string(
        start: ptr_uint,
        line: ptr_uint,
        col: ptr_uint,
        is_cstr: bool,
    ) -> void:
        this.cursor.advance()
        while not this.cursor.at_end():
            let ch = this.cursor.current()
            if ch == '"':
                this.cursor.advance()
                let kind = if is_cstr: T.tk_cstring else: T.tk_string
                this.push_token(kind, start, this.cursor.pos, line, col)
                return

            if ch == '\\':
                this.cursor.advance()
                if not this.cursor.at_end():
                    this.cursor.advance()
                continue

            if token_mod.is_newline(ch):
                # unterminated string on this line
                this.cursor.advance()
                this.push_token(T.tk_string, start, this.cursor.pos, line, col)
                return

            this.cursor.advance()

        this.push_token(T.tk_string, start, this.cursor.pos, line, col)


    ## ── char literal ─────────────────────────────────────────────

    editable function lex_char_literal(
        start: ptr_uint,
        line: ptr_uint,
        col: ptr_uint,
    ) -> void:
        this.cursor.advance()

        if this.cursor.at_end():
            this.push_token(T.tk_char_literal, start, this.cursor.pos, line, col)
            return

        let ch = this.cursor.current()
        if ch == '\\':
            this.cursor.advance()
            if this.cursor.current() == 'x':
                this.cursor.advance()
                this.cursor.advance_by(2)
            else:
                this.cursor.advance()
        else:
            this.cursor.advance()

        if not this.cursor.at_end() and this.cursor.current() == '\'':
            this.cursor.advance()

        this.push_token(T.tk_char_literal, start, this.cursor.pos, line, col)


    ## ── format string (basic, no nested interpolation) ───────────

    editable function lex_format_string(
        start: ptr_uint,
        line: ptr_uint,
        col: ptr_uint,
    ) -> void:
        this.cursor.advance()
        while not this.cursor.at_end():
            let ch = this.cursor.current()
            if ch == '"':
                this.cursor.advance()
                this.push_token(T.tk_fstring, start, this.cursor.pos, line, col)
                return

            if ch == '\\':
                this.cursor.advance()
                if not this.cursor.at_end():
                    this.cursor.advance()
                continue

            if token_mod.is_newline(ch):
                this.cursor.advance()
                this.push_token(T.tk_fstring, start, this.cursor.pos, line, col)
                return

            this.cursor.advance()

        this.push_token(T.tk_fstring, start, this.cursor.pos, line, col)


    ## ── line comment ─────────────────────────────────────────────

    editable function skip_line_comment() -> void:
        while not this.cursor.at_end() and not token_mod.is_newline(this.cursor.current()):
            this.cursor.advance()


    ## ── operators / delimiters ───────────────────────────────────

    editable function lex_operator(
        start: ptr_uint,
        line: ptr_uint,
        col: ptr_uint,
    ) -> void:
        let ch = this.cursor.current()
        let p1 = this.cursor.peek(1)
        let p2 = this.cursor.peek(2)

        # three-char operators
        if ch == '.' and token_is(p1, '.') and token_is(p2, '.'):
            this.cursor.advance_by(3)
            this.push_token(T.tk_ellipsis, start, this.cursor.pos, line, col)
            return

        if ch == '<' and token_is(p1, '<') and token_is(p2, '='):
            this.cursor.advance_by(3)
            this.push_token(T.tk_shift_left_equal, start, this.cursor.pos, line, col)
            return

        if ch == '>' and token_is(p1, '>') and token_is(p2, '='):
            this.cursor.advance_by(3)
            this.push_token(T.tk_shift_right_equal, start, this.cursor.pos, line, col)
            return

        # two-char operators
        if ch == '-' and token_is(p1, '>'):
            this.push_two_char(T.tk_arrow, start, line, col)
            return
        if ch == '.' and token_is(p1, '.'):
            this.push_two_char(T.tk_dot_dot, start, line, col)
            return
        if ch == '<' and token_is(p1, '<'):
            this.push_two_char(T.tk_shift_left, start, line, col)
            return
        if ch == '>' and token_is(p1, '>'):
            this.push_two_char(T.tk_shift_right, start, line, col)
            return
        if ch == '+' and token_is(p1, '='):
            this.push_two_char(T.tk_plus_equal, start, line, col)
            return
        if ch == '-' and token_is(p1, '='):
            this.push_two_char(T.tk_minus_equal, start, line, col)
            return
        if ch == '*' and token_is(p1, '='):
            this.push_two_char(T.tk_star_equal, start, line, col)
            return
        if ch == '/' and token_is(p1, '='):
            this.push_two_char(T.tk_slash_equal, start, line, col)
            return
        if ch == '%' and token_is(p1, '='):
            this.push_two_char(T.tk_percent_equal, start, line, col)
            return
        if ch == '&' and token_is(p1, '='):
            this.push_two_char(T.tk_amp_equal, start, line, col)
            return
        if ch == '|' and token_is(p1, '='):
            this.push_two_char(T.tk_pipe_equal, start, line, col)
            return
        if ch == '^' and token_is(p1, '='):
            this.push_two_char(T.tk_caret_equal, start, line, col)
            return
        if ch == '=' and token_is(p1, '='):
            this.push_two_char(T.tk_equal_equal, start, line, col)
            return
        if ch == '!' and token_is(p1, '='):
            this.push_two_char(T.tk_bang_equal, start, line, col)
            return
        if ch == '<' and token_is(p1, '='):
            this.push_two_char(T.tk_less_equal, start, line, col)
            return
        if ch == '>' and token_is(p1, '='):
            this.push_two_char(T.tk_greater_equal, start, line, col)
            return

        # single-char
        let kind = this.single_char_kind(ch)
        this.cursor.advance()
        this.push_token(kind, start, this.cursor.pos, line, col)


    editable function push_two_char(
        kind: T,
        start: ptr_uint,
        line: ptr_uint,
        col: ptr_uint,
    ) -> void:
        this.cursor.advance_by(2)
        this.push_token(kind, start, this.cursor.pos, line, col)


    function single_char_kind(ch: ubyte) -> T:
        match ch:
            '(':
                return T.tk_lparen
            ')':
                return T.tk_rparen
            '[':
                return T.tk_lbracket
            ']':
                return T.tk_rbracket
            ':':
                return T.tk_colon
            ',':
                return T.tk_comma
            '.':
                return T.tk_dot
            '@':
                return T.tk_at
            '?':
                return T.tk_question
            '+':
                return T.tk_plus
            '-':
                return T.tk_minus
            '*':
                return T.tk_star
            '/':
                return T.tk_slash
            '%':
                return T.tk_percent
            '&':
                return T.tk_amp
            '|':
                return T.tk_pipe
            '^':
                return T.tk_caret
            '~':
                return T.tk_tilde
            '<':
                return T.tk_less
            '>':
                return T.tk_greater
            '=':
                return T.tk_equal
            _:
                return T.tk_identifier


    ## ── indentation ───────────────────────────────────────────────

    editable function handle_indent() -> void:
        # count leading spaces, emit indent/dedent tokens
        var spaces: ptr_uint = 0
        let start_pos = this.cursor.pos
        let line = this.cursor.line
        let col = this.cursor.col

        # count spaces at the start of the new line
        while not this.cursor.at_end() and this.cursor.current() == ' ':
            this.cursor.advance()
            spaces += 1

        # empty line or comment-only line — skip indentation
        if this.cursor.at_end() or this.cursor.current() == '#':
            return

        # skip if continuation pending (previous line ended with binary operator)
        if this.continuation_pending:
            this.continuation_pending = false
            return

        # skip if inside grouping
        if this.grouping_depth > 0:
            return

        let new_level = spaces
        let top = this.indent_level()

        if new_level > top:
            this.push_token(T.tk_indent, start_pos, this.cursor.pos, line, col)
            this.indent_stack.push(spaces)
        else if new_level < top:
            while this.indent_stack.len > 0 and this.indent_level() > new_level:
                this.indent_stack.pop()
                this.push_token(T.tk_dedent, start_pos, this.cursor.pos, line, col)


    function indent_level() -> ptr_uint:
        if this.indent_stack.len == 0:
            return 0
        let result = this.indent_stack.get(this.indent_stack.len - 1) else:
            return 0
        unsafe:
            return read(result)


    ## ── finish ───────────────────────────────────────────────────

    editable function finish() -> void:
        while this.indent_stack.len > 0:
            this.indent_stack.pop()
            this.push_token(
                T.tk_dedent,
                this.cursor.pos,
                this.cursor.pos,
                this.cursor.line,
                this.cursor.col,
            )
        this.push_token(
            T.tk_eof,
            this.cursor.pos,
            this.cursor.pos,
            this.cursor.line,
            this.cursor.col,
        )


## ── helper ──────────────────────────────────────────────────────

function token_is(
    opt: Option[ubyte],
    expected: ubyte,
) -> bool:
    match opt:
        Option.some as payload:
            return payload.value == expected
        Option.none:
            return false
