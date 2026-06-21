import std.str
import std.vec as vec

import mtc.lexer.token

function is_alpha(ch: ubyte) -> bool:
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z')

function is_digit(ch: ubyte) -> bool:
    return ch >= '0' and ch <= '9'

function is_alphanumeric(ch: ubyte) -> bool:
    return is_alpha(ch) or is_digit(ch) or ch == '_'

function is_hex_digit(ch: ubyte) -> bool:
    return is_digit(ch) or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F')

function is_identifier_start(ch: ubyte) -> bool:
    return is_alpha(ch) or ch == '_'

function is_binary_digit(ch: ubyte) -> bool:
    return ch == '0' or ch == '1'


public struct Lexer:
    source: str
    pos: ptr_uint
    line: ptr_uint
    column: ptr_uint
    tokens: vec.Vec[token.Token]
    indent_stack: vec.Vec[ptr_uint]
    grouping_depth: ptr_uint
    continuation_pending: bool


extending Lexer:
    public static function create(source: str) -> Lexer:
        var indent_stack = vec.Vec[ptr_uint].create()
        indent_stack.push(0)
        return Lexer(
            source = source,
            pos = 0,
            line = 1,
            column = 1,
            tokens = vec.Vec[token.Token].create(),
            indent_stack = indent_stack,
            grouping_depth = 0,
            continuation_pending = false
        )


    function at_end() -> bool:
        return this.pos >= this.source.len


    function peek() -> ubyte:
        if this.pos >= this.source.len:
            return 0
        return this.source.byte_at(this.pos)


    function peek_at(offset: ptr_uint) -> ubyte:
        if offset >= this.source.len:
            return 0
        return this.source.byte_at(offset)


    editable function advance() -> void:
        if this.pos >= this.source.len:
            return
        let ch = this.source.byte_at(this.pos)
        this.pos += 1
        if ch == '\n':
            this.line += 1
            this.column = 1
        else:
            this.column += 1


    function at_line_start() -> bool:
        return this.column == 1


    editable function skip_spaces() -> void:
        while this.pos < this.source.len and this.peek() == ' ':
            this.advance()


    editable function skip_to_end_of_line() -> void:
        while this.pos < this.source.len and this.peek() != '\n':
            this.advance()


    editable function skip_blank_lines() -> void:
        while this.pos < this.source.len:
            if this.peek() == '\n':
                this.advance()
            else if this.peek() == ' ':
                var scan = this.pos
                while scan < this.source.len and this.source.byte_at(scan) == ' ':
                    scan += 1
                if scan >= this.source.len:
                    break
                let next = this.source.byte_at(scan)
                if next == '\n':
                    while this.pos < this.source.len and this.peek() != '\n':
                        this.advance()
                    this.advance()
                else if next == '#':
                    this.skip_to_end_of_line()
                else:
                    break
            else if this.peek() == '#':
                this.skip_to_end_of_line()
            else:
                break


    ## Count leading spaces at current position in source.
    function count_indent() -> ptr_uint:
        var count: ptr_uint = 0
        var scan = this.pos
        while scan < this.source.len and this.source.byte_at(scan) == ' ':
            count += 1
            scan += 1
        return count


    ## Emit indent/dedent tokens based on new indentation level.
    editable function handle_indentation() -> void:
        if this.grouping_depth > 0:
            return
        if this.continuation_pending:
            this.continuation_pending = false
            return

        let indent = this.count_indent()

        if indent % 4 != 0:
            fatal("lexer: indentation must be a multiple of 4 spaces")
            return

        let current_indent = this.indent_stack.last() else:
            fatal("lexer: empty indent stack")
            return

        if indent == unsafe: read(current_indent):
            return

        if indent > unsafe: read(current_indent):
            if indent != unsafe: read(current_indent) + 4:
                fatal("lexer: indentation may only increase by 4 spaces at a time")
                return
            this.indent_stack.push(indent)
            this.emit_token(token.TokenKind.tk_indent, "")
            return

        while this.indent_stack.len() > 1:
            let top = this.indent_stack.last() else:
                break
            if unsafe: read(top) <= indent:
                break
            this.indent_stack.pop()
            this.emit_token(token.TokenKind.tk_dedent, "")

        let top = this.indent_stack.last() else:
            fatal("lexer: empty indent stack")
            return
        if unsafe: read(top) != indent:
            fatal("lexer: indentation does not match any open block")
            return


    ## Advance past current line's indentation spaces.
    editable function skip_indent() -> void:
        while this.pos < this.source.len and this.peek() == ' ':
            this.advance()


    ## Emit a token at the current position.
    editable function emit_token(kind: token.TokenKind, lexeme: str) -> void:
        this.tokens.push(token.Token(kind = kind, lexeme = lexeme, line = this.line, column = this.column))


    ## Check if a token kind is a line continuation operator.
    function is_line_continuation(kind: token.TokenKind) -> bool:
        return kind == token.TokenKind.tk_plus or
            kind == token.TokenKind.tk_minus or
            kind == token.TokenKind.tk_star or
            kind == token.TokenKind.tk_slash or
            kind == token.TokenKind.tk_percent or
            kind == token.TokenKind.tk_pipe or
            kind == token.TokenKind.tk_amp or
            kind == token.TokenKind.tk_caret or
            kind == token.TokenKind.tk_or or
            kind == token.TokenKind.tk_and or
            kind == token.TokenKind.tk_equal_equal or
            kind == token.TokenKind.tk_bang_equal or
            kind == token.TokenKind.tk_less or
            kind == token.TokenKind.tk_less_equal or
            kind == token.TokenKind.tk_greater or
            kind == token.TokenKind.tk_greater_equal or
            kind == token.TokenKind.tk_shift_left or
            kind == token.TokenKind.tk_shift_right or
            kind == token.TokenKind.tk_dot_dot


    ## Look up a keyword string and return its token.TokenKind, or tk_identifier.
    function keyword_kind(lexeme: str) -> token.TokenKind:
        if lexeme == "align_of":
            return token.TokenKind.tk_align_of
        else if lexeme == "and":
            return token.TokenKind.tk_and
        else if lexeme == "as":
            return token.TokenKind.tk_as
        else if lexeme == "async":
            return token.TokenKind.tk_async
        else if lexeme == "attribute":
            return token.TokenKind.tk_attribute
        else if lexeme == "attribute_arg":
            return token.TokenKind.tk_attribute_arg
        else if lexeme == "attribute_of":
            return token.TokenKind.tk_attribute_of
        else if lexeme == "attributes_of":
            return token.TokenKind.tk_attributes_of
        else if lexeme == "await":
            return token.TokenKind.tk_await
        else if lexeme == "break":
            return token.TokenKind.tk_break
        else if lexeme == "callable_of":
            return token.TokenKind.tk_callable_of
        else if lexeme == "compiler_flag":
            return token.TokenKind.tk_compiler_flag
        else if lexeme == "const":
            return token.TokenKind.tk_const
        else if lexeme == "consuming":
            return token.TokenKind.tk_consuming
        else if lexeme == "continue":
            return token.TokenKind.tk_continue
        else if lexeme == "defer":
            return token.TokenKind.tk_defer
        else if lexeme == "detach":
            return token.TokenKind.tk_detach
        else if lexeme == "dyn":
            return token.TokenKind.tk_dyn
        else if lexeme == "editable":
            return token.TokenKind.tk_editable
        else if lexeme == "else":
            return token.TokenKind.tk_else
        else if lexeme == "emit":
            return token.TokenKind.tk_emit
        else if lexeme == "enum":
            return token.TokenKind.tk_enum
        else if lexeme == "event":
            return token.TokenKind.tk_event
        else if lexeme == "extending":
            return token.TokenKind.tk_extending
        else if lexeme == "external":
            return token.TokenKind.tk_external
        else if lexeme == "false":
            return token.TokenKind.tk_false
        else if lexeme == "field_of":
            return token.TokenKind.tk_field_of
        else if lexeme == "fields_of":
            return token.TokenKind.tk_fields_of
        else if lexeme == "flags":
            return token.TokenKind.tk_flags
        else if lexeme == "fn":
            return token.TokenKind.tk_fn
        else if lexeme == "for":
            return token.TokenKind.tk_for
        else if lexeme == "foreign":
            return token.TokenKind.tk_foreign
        else if lexeme == "function":
            return token.TokenKind.tk_function
        else if lexeme == "gather":
            return token.TokenKind.tk_gather
        else if lexeme == "has_attribute":
            return token.TokenKind.tk_has_attribute
        else if lexeme == "if":
            return token.TokenKind.tk_if
        else if lexeme == "implements":
            return token.TokenKind.tk_implements
        else if lexeme == "import":
            return token.TokenKind.tk_import
        else if lexeme == "in":
            return token.TokenKind.tk_in
        else if lexeme == "include":
            return token.TokenKind.tk_include
        else if lexeme == "inline":
            return token.TokenKind.tk_inline
        else if lexeme == "inout":
            return token.TokenKind.tk_inout
        else if lexeme == "interface":
            return token.TokenKind.tk_interface
        else if lexeme == "is":
            return token.TokenKind.tk_is
        else if lexeme == "let":
            return token.TokenKind.tk_let
        else if lexeme == "link":
            return token.TokenKind.tk_link
        else if lexeme == "match":
            return token.TokenKind.tk_match
        else if lexeme == "members_of":
            return token.TokenKind.tk_members_of
        else if lexeme == "module":
            return token.TokenKind.tk_module
        else if lexeme == "not":
            return token.TokenKind.tk_not
        else if lexeme == "null":
            return token.TokenKind.tk_null
        else if lexeme == "offset_of":
            return token.TokenKind.tk_offset_of
        else if lexeme == "opaque":
            return token.TokenKind.tk_opaque
        else if lexeme == "or":
            return token.TokenKind.tk_or
        else if lexeme == "out":
            return token.TokenKind.tk_out
        else if lexeme == "parallel":
            return token.TokenKind.tk_parallel
        else if lexeme == "pass":
            return token.TokenKind.tk_pass
        else if lexeme == "proc":
            return token.TokenKind.tk_proc
        else if lexeme == "public":
            return token.TokenKind.tk_public
        else if lexeme == "return":
            return token.TokenKind.tk_return
        else if lexeme == "size_of":
            return token.TokenKind.tk_size_of
        else if lexeme == "static":
            return token.TokenKind.tk_static
        else if lexeme == "static_assert":
            return token.TokenKind.tk_static_assert
        else if lexeme == "struct":
            return token.TokenKind.tk_struct
        else if lexeme == "true":
            return token.TokenKind.tk_true
        else if lexeme == "type":
            return token.TokenKind.tk_type
        else if lexeme == "union":
            return token.TokenKind.tk_union
        else if lexeme == "unsafe":
            return token.TokenKind.tk_unsafe
        else if lexeme == "var":
            return token.TokenKind.tk_var
        else if lexeme == "variant":
            return token.TokenKind.tk_variant
        else if lexeme == "when":
            return token.TokenKind.tk_when
        else if lexeme == "while":
            return token.TokenKind.tk_while

        return token.TokenKind.tk_identifier


    ## Lex an identifier or keyword.
    editable function lex_identifier() -> void:
        let start = this.pos
        let start_column = this.column
        this.advance()
        while this.pos < this.source.len and is_alphanumeric(this.peek()):
            this.advance()
        let lexeme = this.source.slice(start, this.pos - start)
        let kind = this.keyword_kind(lexeme)
        this.tokens.push(token.Token(kind = kind, lexeme = lexeme, line = this.line, column = start_column))


    ## Lex an integer or float literal.
    editable function lex_number() -> void:
        let start = this.pos
        let start_column = this.column
        var is_float = false

        if this.peek() == '0':
            let next = this.peek_at(this.pos + 1)
            if next == 'x' or next == 'X':
                this.advance()
                this.advance()
                while this.pos < this.source.len and (is_hex_digit(this.peek()) or this.peek() == '_'):
                    this.advance()
            else if next == 'b' or next == 'B':
                this.advance()
                this.advance()
                while this.pos < this.source.len and (is_binary_digit(this.peek()) or this.peek() == '_'):
                    this.advance()
            else:
                while this.pos < this.source.len and (is_digit(this.peek()) or this.peek() == '_'):
                    this.advance()
        else:
            while this.pos < this.source.len and (is_digit(this.peek()) or this.peek() == '_'):
                this.advance()

        if this.peek() == '.' and is_digit(this.peek_at(this.pos + 1)):
            is_float = true
            this.advance()
            while this.pos < this.source.len and (is_digit(this.peek()) or this.peek() == '_'):
                this.advance()

        if this.peek() == 'e' or this.peek() == 'E':
            let next = this.peek_at(this.pos + 1)
            if is_digit(next) or next == '+' or next == '-':
                is_float = true
                this.advance()
                if this.peek() == '+' or this.peek() == '-':
                    this.advance()
                while this.pos < this.source.len and (is_digit(this.peek()) or this.peek() == '_'):
                    this.advance()

        this.scan_numeric_suffix()

        if is_float:
            this.scan_float_suffix()

        let lexeme = this.source.slice(start, this.pos - start)
        if is_float:
            this.tokens.push(token.Token(kind = token.TokenKind.tk_float, lexeme = lexeme, line = this.line, column = start_column))
        else:
            this.tokens.push(token.Token(kind = token.TokenKind.tk_integer, lexeme = lexeme, line = this.line, column = start_column))


    editable function scan_numeric_suffix() -> void:
        let ch = this.peek()
        if ch == 'u':
            this.advance()
            let next = this.peek()
            if next == 'b':
                this.advance()
            else if next == 's':
                this.advance()
            else if next == 'l':
                this.advance()
        else if ch == 'i':
            this.advance()
            let next = this.peek()
            if next == 'z':
                this.advance()
        else if ch == 'b' or ch == 's':
            this.advance()
        else if ch == 'l':
            this.advance()
        else if ch == 'z':
            this.advance()


    editable function scan_float_suffix() -> void:
        let ch = this.peek()
        if ch == 'f' or ch == 'd':
            this.advance()


    ## Lex a string literal ("..." or c"...").
    editable function lex_string(cstring: bool) -> void:
        let start = this.pos
        let start_line = this.line
        let start_column = this.column
        if cstring:
            this.advance()
        this.advance()

        while this.pos < this.source.len:
            let ch = this.peek()
            if ch == '"':
                this.advance()
                break
            else if ch == '\\':
                this.advance()
                if this.pos < this.source.len:
                    this.advance()
            else if ch == '\n':
                fatal("lexer: unterminated string literal")
                return
            else:
                this.advance()

        if this.pos >= this.source.len:
            fatal("lexer: unterminated string literal")
            return

        var end_pos = this.pos

        while true:
            var scan = end_pos

            if scan < this.source.len and this.source.byte_at(scan) == '\n':
                scan += 1

            while scan < this.source.len and this.source.byte_at(scan) == ' ':
                scan += 1

            if scan >= this.source.len:
                break

            if cstring and scan < this.source.len and this.source.byte_at(scan) == 'c':
                scan += 1

            if scan >= this.source.len or this.source.byte_at(scan) != '"':
                break

            scan += 1

            var seg_end = scan
            var found_close = false
            while scan < this.source.len:
                let inner = this.source.byte_at(scan)
                if inner == '"':
                    scan += 1
                    seg_end = scan
                    found_close = true
                    break
                else if inner == '\\':
                    scan += 1
                    if scan < this.source.len:
                        scan += 1
                else if inner == '\n':
                    break
                else:
                    scan += 1

            if not found_close:
                break

            end_pos = seg_end

            var only_spaces_after = true
            var check = scan
            while check < this.source.len:
                let rch = this.source.byte_at(check)
                if rch == '\n':
                    break
                if rch != ' ':
                    only_spaces_after = false
                    break
                check += 1
            if not only_spaces_after:
                break

        var prev_pos = this.pos
        this.pos = end_pos

        var scan_pos = prev_pos
        while scan_pos < this.pos:
            let b = this.source.byte_at(scan_pos)
            scan_pos += 1
            if b == '\n':
                this.line += 1
                this.column = 1
            else:
                this.column += 1

        let lexeme = this.source.slice(start, this.pos - start)
        if cstring:
            this.tokens.push(token.Token(kind = token.TokenKind.tk_cstring, lexeme = lexeme, line = start_line, column = start_column))
        else:
            this.tokens.push(token.Token(kind = token.TokenKind.tk_string, lexeme = lexeme, line = start_line, column = start_column))


    ## Lex a format string literal f"...".
    editable function lex_format_string() -> void:
        let start = this.pos
        let start_column = this.column
        this.advance()
        this.advance()

        while this.pos < this.source.len:
            let ch = this.peek()
            if ch == '"':
                this.advance()
                let lexeme = this.source.slice(start, this.pos - start)
                this.tokens.push(token.Token(kind = token.TokenKind.tk_fstring, lexeme = lexeme, line = this.line, column = start_column))
                return
            else if ch == '#' and this.peek_at(this.pos + 1) == '{':
                this.advance()
                this.advance()
                this.skip_format_interpolation()
            else if ch == '\\':
                this.advance()
                if this.pos < this.source.len:
                    this.advance()
            else if ch == '\n':
                this.advance()
            else:
                this.advance()

        fatal("lexer: unterminated format string literal")


    editable function skip_format_interpolation() -> void:
        var depth: ptr_uint = 1
        while this.pos < this.source.len and depth > 0:
            let ch = this.peek()
            if ch == '{':
                depth += 1
                this.advance()
            else if ch == '}':
                depth -= 1
                if depth > 0:
                    this.advance()
            else if ch == '"':
                this.advance()
                while this.pos < this.source.len and this.peek() != '"':
                    if this.peek() == '\\':
                        this.advance()
                        if this.pos < this.source.len:
                            this.advance()
                    else:
                        this.advance()
                if this.pos < this.source.len:
                    this.advance()
            else if ch == '\'':
                this.advance()
                if this.peek() == '\\':
                    this.advance()
                    if this.pos < this.source.len:
                        this.advance()
                else if this.pos < this.source.len:
                    this.advance()
                if this.pos < this.source.len and this.peek() == '\'':
                    this.advance()
            else:
                this.advance()

        if depth > 0:
            fatal("lexer: unterminated format interpolation")


    ## Lex a character literal 'a' or '\n'.
    editable function lex_char_literal() -> void:
        let start = this.pos
        let start_column = this.column
        this.advance()

        if this.pos >= this.source.len or this.peek() == '\n':
            fatal("lexer: unterminated character literal")
            return

        let ch = this.peek()
        if ch == '\\':
            this.advance()
            if this.pos >= this.source.len or this.peek() == '\n':
                fatal("lexer: unterminated escape in character literal")
                return
            let esc = this.peek()
            if esc == 'x':
                this.advance()
                if this.peek() == '\n':
                    fatal("lexer: unterminated hex escape in character literal")
                    return
                var i: ptr_uint = 0
                while i < 2 and this.pos < this.source.len and is_hex_digit(this.peek()):
                    this.advance()
                    i += 1
            else:
                this.advance()
        else:
            this.advance()

        if this.pos >= this.source.len or this.peek() == '\n' or this.peek() != '\'':
            fatal("lexer: expected closing ' in character literal")
            return
        this.advance()

        let lexeme = this.source.slice(start, this.pos - start)
        this.tokens.push(token.Token(kind = token.TokenKind.tk_char_literal, lexeme = lexeme, line = this.line, column = start_column))


    ## Lex a heredoc: <<-TAG, c<<-TAG, or f<<-TAG.
    editable function lex_heredoc(cstring: bool, format: bool) -> void:
        let start = this.pos
        let start_column = this.column
        let start_line = this.line

        this.advance()
        this.advance()
        this.advance()
        if cstring:
            this.advance()
        if format:
            this.advance()

        if not is_identifier_start(this.peek()):
            fatal("lexer: expected heredoc tag identifier")
            return

        let tag_start = this.pos
        while this.pos < this.source.len and is_alphanumeric(this.peek()):
            this.advance()
        let tag = this.source.slice(tag_start, this.pos - tag_start)

        if this.pos < this.source.len and this.peek() != '\n':
            fatal("lexer: unexpected characters after heredoc tag")
            return

        var content_lines = vec.Vec[str].create()
        var terminator_found = false
        var terminator_end: ptr_uint = 0
        var terminator_line: ptr_uint = 0
        var terminator_column: ptr_uint = 0

        while this.pos < this.source.len:
            let line_start = this.pos
            let line_start_line = this.line
            let line_start_column = this.column

            while this.pos < this.source.len and this.peek() != '\n':
                this.advance()

            let line_len = this.pos - line_start
            let raw_line = this.source.slice(line_start, line_len)

            if this.pos < this.source.len:
                this.advance()

            if this.is_heredoc_terminator(raw_line, tag):
                terminator_found = true
                terminator_end = line_start
                terminator_line = line_start_line
                terminator_column = line_start_column
                break

            content_lines.push(raw_line)

        if not terminator_found:
            fatal("lexer: unterminated heredoc literal")
            return

        let lexeme = this.source.slice(start, terminator_end - start)
        if cstring:
            this.tokens.push(token.Token(kind = token.TokenKind.tk_cstring, lexeme = lexeme, line = start_line, column = start_column))
        else if format:
            this.tokens.push(token.Token(kind = token.TokenKind.tk_fstring, lexeme = lexeme, line = start_line, column = start_column))
        else:
            this.tokens.push(token.Token(kind = token.TokenKind.tk_string, lexeme = lexeme, line = start_line, column = start_column))


    function is_heredoc_terminator(line: str, tag: str) -> bool:
        var i: ptr_uint = 0
        while i < line.len and line.byte_at(i) == ' ':
            i += 1
        let trimmed = line.slice(i, line.len - i)
        return trimmed == tag


    ## Lex an operator or punctuation symbol.
    editable function lex_symbol() -> void:
        let start = this.pos
        let start_column = this.column

        let ch1 = this.peek()
        let ch2 = this.peek_at(this.pos + 1)
        let ch3 = this.peek_at(this.pos + 2)

        if ch1 == '.' and ch2 == '.' and ch3 == '.':
            this.advance()
            this.advance()
            this.advance()
            this.emit_symbol(token.TokenKind.tk_ellipsis, start, start_column)
            return

        if ch1 == '<' and ch2 == '<' and ch3 == '=':
            this.advance()
            this.advance()
            this.advance()
            this.emit_symbol(token.TokenKind.tk_shift_left_equal, start, start_column)
            return

        if ch1 == '>' and ch2 == '>' and ch3 == '=':
            this.advance()
            this.advance()
            this.advance()
            this.emit_symbol(token.TokenKind.tk_shift_right_equal, start, start_column)
            return

        if ch1 == '-' and ch2 == '>':
            this.advance()
            this.advance()
            this.emit_symbol(token.TokenKind.tk_arrow, start, start_column)
            return

        if ch1 == '.' and ch2 == '.':
            this.advance()
            this.advance()
            this.emit_symbol(token.TokenKind.tk_dot_dot, start, start_column)
            return

        if ch1 == '<' and ch2 == '<':
            this.advance()
            this.advance()
            this.emit_symbol(token.TokenKind.tk_shift_left, start, start_column)
            return

        if ch1 == '>' and ch2 == '>':
            this.advance()
            this.advance()
            this.emit_symbol(token.TokenKind.tk_shift_right, start, start_column)
            return

        if ch1 == '+' and ch2 == '=':
            this.lex_two_char_symbol(token.TokenKind.tk_plus_equal, start, start_column)
            return
        if ch1 == '-' and ch2 == '=':
            this.lex_two_char_symbol(token.TokenKind.tk_minus_equal, start, start_column)
            return
        if ch1 == '*' and ch2 == '=':
            this.lex_two_char_symbol(token.TokenKind.tk_star_equal, start, start_column)
            return
        if ch1 == '/' and ch2 == '=':
            this.lex_two_char_symbol(token.TokenKind.tk_slash_equal, start, start_column)
            return
        if ch1 == '%' and ch2 == '=':
            this.lex_two_char_symbol(token.TokenKind.tk_percent_equal, start, start_column)
            return
        if ch1 == '&' and ch2 == '=':
            this.lex_two_char_symbol(token.TokenKind.tk_amp_equal, start, start_column)
            return
        if ch1 == '|' and ch2 == '=':
            this.lex_two_char_symbol(token.TokenKind.tk_pipe_equal, start, start_column)
            return
        if ch1 == '^' and ch2 == '=':
            this.lex_two_char_symbol(token.TokenKind.tk_caret_equal, start, start_column)
            return
        if ch1 == '=' and ch2 == '=':
            this.lex_two_char_symbol(token.TokenKind.tk_equal_equal, start, start_column)
            return
        if ch1 == '!' and ch2 == '=':
            this.lex_two_char_symbol(token.TokenKind.tk_bang_equal, start, start_column)
            return
        if ch1 == '<' and ch2 == '=':
            this.lex_two_char_symbol(token.TokenKind.tk_less_equal, start, start_column)
            return
        if ch1 == '>' and ch2 == '=':
            this.lex_two_char_symbol(token.TokenKind.tk_greater_equal, start, start_column)
            return

        this.advance()
        let kind = this.single_char_kind(ch1)
        if ch1 == '(' or ch1 == '[':
            this.grouping_depth += 1
        else if ch1 == ')' or ch1 == ']':
            if this.grouping_depth > 0:
                this.grouping_depth -= 1
        this.emit_symbol(kind, start, start_column)


    editable function lex_two_char_symbol(kind: token.TokenKind, start: ptr_uint, start_column: ptr_uint) -> void:
        this.advance()
        this.advance()
        this.emit_symbol(kind, start, start_column)


    function single_char_kind(ch: ubyte) -> token.TokenKind:
        if ch == '&':
            return token.TokenKind.tk_amp
        else if ch == '@':
            return token.TokenKind.tk_at
        else if ch == ':':
            return token.TokenKind.tk_colon
        else if ch == ',':
            return token.TokenKind.tk_comma
        else if ch == '^':
            return token.TokenKind.tk_caret
        else if ch == '.':
            return token.TokenKind.tk_dot
        else if ch == '(':
            return token.TokenKind.tk_lparen
        else if ch == ')':
            return token.TokenKind.tk_rparen
        else if ch == '|':
            return token.TokenKind.tk_pipe
        else if ch == '[':
            return token.TokenKind.tk_lbracket
        else if ch == ']':
            return token.TokenKind.tk_rbracket
        else if ch == '?':
            return token.TokenKind.tk_question
        else if ch == '=':
            return token.TokenKind.tk_equal
        else if ch == '+':
            return token.TokenKind.tk_plus
        else if ch == '-':
            return token.TokenKind.tk_minus
        else if ch == '*':
            return token.TokenKind.tk_star
        else if ch == '/':
            return token.TokenKind.tk_slash
        else if ch == '%':
            return token.TokenKind.tk_percent
        else if ch == '<':
            return token.TokenKind.tk_less
        else if ch == '>':
            return token.TokenKind.tk_greater
        else if ch == '~':
            return token.TokenKind.tk_tilde
        fatal("lexer: unexpected character")
        return token.TokenKind.tk_eof


    editable function emit_symbol(kind: token.TokenKind, start: ptr_uint, start_column: ptr_uint) -> void:
        let lexeme = this.source.slice(start, this.pos - start)
        this.tokens.push(token.Token(kind = kind, lexeme = lexeme, line = this.line, column = start_column))


    ## Main lexing loop.
    public editable function lex() -> vec.Vec[token.Token]:
        while this.pos < this.source.len:
            if this.at_line_start():
                this.skip_blank_lines()
                if this.pos >= this.source.len:
                    break

                let indent = this.count_indent()
                this.handle_indentation()
                this.skip_indent()

                if this.pos < this.source.len and this.peek() == '\n':
                    this.advance()
                    continue

            if this.pos >= this.source.len:
                break

            let ch = this.peek()

            if ch == ' ':
                this.skip_spaces()
                continue

            if ch == '#':
                this.skip_to_end_of_line()
                continue

            if ch == '\n':
                let last_kind = this.last_token_kind()
                if this.is_line_continuation(last_kind):
                    this.continuation_pending = true
                else if this.grouping_depth == 0:
                    this.emit_token(token.TokenKind.tk_newline, "\n")
                this.advance()
                continue

            if ch == 'c' and this.peek_at(this.pos + 1) == '"':
                this.lex_string(true)
                continue

            if ch == 'c' and this.pos + 4 < this.source.len:
                let c2 = this.peek_at(this.pos + 1)
                let c3 = this.peek_at(this.pos + 2)
                let c4 = this.peek_at(this.pos + 3)
                if c2 == '<' and c3 == '<' and c4 == '-':
                    if is_identifier_start(this.peek_at(this.pos + 4)):
                        this.lex_heredoc(true, false)
                        continue

            if ch == 'f' and this.peek_at(this.pos + 1) == '"':
                this.lex_format_string()
                continue

            if ch == 'f' and this.pos + 4 < this.source.len:
                let c2 = this.peek_at(this.pos + 1)
                let c3 = this.peek_at(this.pos + 2)
                let c4 = this.peek_at(this.pos + 3)
                if c2 == '<' and c3 == '<' and c4 == '-':
                    if is_identifier_start(this.peek_at(this.pos + 4)):
                        this.lex_heredoc(false, true)
                        continue

            if ch == '<' and this.pos + 3 < this.source.len:
                let c2 = this.peek_at(this.pos + 1)
                let c3 = this.peek_at(this.pos + 2)
                if c2 == '<' and c3 == '-':
                    if is_identifier_start(this.peek_at(this.pos + 3)):
                        this.lex_heredoc(false, false)
                        continue

            if ch == '"':
                this.lex_string(false)
                continue

            if ch == '\'':
                this.lex_char_literal()
                continue

            if is_identifier_start(ch):
                this.lex_identifier()
                continue

            if is_digit(ch):
                this.lex_number()
                continue

            this.lex_symbol()

        while this.indent_stack.len() > 1:
            this.indent_stack.pop()
            this.emit_token(token.TokenKind.tk_dedent, "")

        this.emit_token(token.TokenKind.tk_eof, "")
        return this.tokens


    function last_token_kind() -> token.TokenKind:
        if this.tokens.len() == 0:
            return token.TokenKind.tk_eof
        let last = this.tokens.last() else:
            return token.TokenKind.tk_eof
        return unsafe: read(last).kind
