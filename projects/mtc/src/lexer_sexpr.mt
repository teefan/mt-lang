import std.str
import std.string as string
import std.stdio as stdio
import stdio_ext
import lexer


public function print_token_sexpr(tok: lexer.Token) -> void:
    stdio.print_format("(:{} :type ")
    stdio_ext.print_quoted_str(lexer.kind_name(tok.kind))
    stdio.print_format(" :lexeme ")
    stdio_ext.print_quoted_str(tok.lexeme)
    stdio.print_format(" :literal ")
    print_token_literal(tok)
    stdio.print_format(" :line %d :column %d :start_offset %lu :end_offset %lu)",
        tok.line, tok.column, tok.start_offset, tok.end_offset)


function print_token_literal(tok: lexer.Token) -> void:
    if tok.kind == lexer.TOK_INTEGER:
        stdio.print_format("%lu", parse_int_lexeme(tok.lexeme))
    else if tok.kind == lexer.TOK_CHAR_LITERAL:
        stdio.print_format("%lu", parse_char_lexeme(tok.lexeme))
    else if tok.kind == lexer.TOK_KW_TRUE:
        stdio.print_format("true")
    else if tok.kind == lexer.TOK_KW_FALSE:
        stdio.print_format("false")
    else if tok.kind == lexer.TOK_STRING:
        print_string_literal(tok.lexeme)
    else if tok.kind == lexer.TOK_CSTRING:
        print_string_literal(tok.lexeme)
    else if tok.kind == lexer.TOK_FLOAT:
        print_float_literal(tok.lexeme)
    else if tok.kind == lexer.TOK_FSTRING:
        print_fstring_literal(tok.lexeme, tok.line, tok.column)
    else:
        stdio.print_format("nil")


function parse_int_lexeme(lexeme: str) -> ptr_uint:
    var i: ptr_uint = 0
    var base: ptr_uint = 10
    if lexeme.len >= 2 and lexeme.byte_at(0) == '0':
        let c = lexeme.byte_at(1)
        if c == 'x' or c == 'X':
            base = 16
            i = 2
        else if c == 'b' or c == 'B':
            base = 2
            i = 2
    var acc: ptr_uint = 0
    while i < lexeme.len:
        let b = lexeme.byte_at(i)
        if b == '_':
            i += 1
            continue
        var d: ptr_uint = 0
        if b >= '0' and b <= '9':
            d = ptr_uint<-(b - '0')
        else if base == 16 and b >= 'a' and b <= 'f':
            d = ptr_uint<-(b - 'a') + 10
        else if base == 16 and b >= 'A' and b <= 'F':
            d = ptr_uint<-(b - 'A') + 10
        else:
            break
        acc = acc * base + d
        i += 1
    return acc


function parse_char_lexeme(lexeme: str) -> ptr_uint:
    if lexeme.len < 3:
        return 0
    let c1 = lexeme.byte_at(1)
    if c1 != '\\':
        return ptr_uint<-c1
    let e = lexeme.byte_at(2)
    if e == 'n':
        return 10
    if e == 'r':
        return 13
    if e == 't':
        return 9
    if e == '0':
        return 0
    if e == '\'':
        return 39
    if e == '"':
        return 34
    if e == '\\':
        return 92
    if e == 'x' or e == 'X':
        var v: ptr_uint = 0
        var k: ptr_uint = 3
        while k < lexeme.len:
            let hb = lexeme.byte_at(k)
            if hb == '\'':
                break
            var d: ptr_uint = 0
            if hb >= '0' and hb <= '9':
                d = ptr_uint<-(hb - '0')
            else if hb >= 'a' and hb <= 'f':
                d = ptr_uint<-(hb - 'a') + 10
            else if hb >= 'A' and hb <= 'F':
                d = ptr_uint<-(hb - 'A') + 10
            else:
                break
            v = v * 16 + d
            k += 1
        return v
    return ptr_uint<-e


function print_escaped_byte(b: ubyte) -> void:
    if b == '\n':
        stdio.print_char('\\')
        stdio.print_char('n')
    else if b == '\r':
        stdio.print_char('\\')
        stdio.print_char('r')
    else if b == '\t':
        stdio.print_char('\\')
        stdio.print_char('t')
    else if b == '\\':
        stdio.print_char('\\')
        stdio.print_char('\\')
    else if b == '"':
        stdio.print_char('\\')
        stdio.print_char('"')
    else:
        stdio.print_char(b)


function decode_str_escape(e: ubyte) -> ubyte:
    if e == 'n':
        return 10
    if e == 'r':
        return 13
    if e == 't':
        return 9
    if e == '0':
        return 0
    if e == '"':
        return 34
    if e == '\'':
        return 39
    if e == '\\':
        return 92
    return e


function is_heredoc_lexeme(lexeme: str) -> bool:
    if lexeme.len >= 3 and lexeme.byte_at(0) == '<' and lexeme.byte_at(1) == '<' and lexeme.byte_at(2) == '-':
        return true
    if lexeme.len >= 4 and lexeme.byte_at(0) == 'c' and lexeme.byte_at(1) == '<' and lexeme.byte_at(2) == '<' and lexeme.byte_at(3) == '-':
        return true
    return false


function print_inline_string_value(lexeme: str) -> void:
    var i: ptr_uint = 0
    while i < lexeme.len:
        if lexeme.byte_at(i) == '"':
            i += 1
            while i < lexeme.len:
                let c = lexeme.byte_at(i)
                if c == '"':
                    i += 1
                    break
                if c == '\\' and i + 1 < lexeme.len:
                    print_escaped_byte(decode_str_escape(lexeme.byte_at(i + 1)))
                    i += 2
                else:
                    print_escaped_byte(c)
                    i += 1
        else:
            i += 1


function count_leading_spaces_at(lexeme: str, start: ptr_uint, line_end: ptr_uint) -> ptr_uint:
    var i = start
    while i < line_end and lexeme.byte_at(i) == ' ':
        i += 1
    return i - start


function is_blank_line(lexeme: str, start: ptr_uint, line_end: ptr_uint) -> bool:
    var i = start
    while i < line_end:
        let b = lexeme.byte_at(i)
        if b != ' ' and b != '\t' and b != '\r' and b != 12 and b != 11 and b != 0:
            return false
        i += 1
    return true


function heredoc_margin(lexeme: str, body_start: ptr_uint, body_end: ptr_uint) -> ptr_uint:
    var margin: ptr_uint = 0
    var found = false
    var i = body_start
    while i < body_end:
        var line_nl = i
        while line_nl < body_end and lexeme.byte_at(line_nl) != '\n':
            line_nl += 1
        if not is_blank_line(lexeme, i, line_nl):
            let sp = count_leading_spaces_at(lexeme, i, line_nl)
            if not found or sp < margin:
                margin = sp
                found = true
        i = line_nl + 1
    return margin


function print_heredoc_string_value(lexeme: str) -> void:
    var first_nl: ptr_uint = 0
    while first_nl < lexeme.len and lexeme.byte_at(first_nl) != '\n':
        first_nl += 1
    if first_nl >= lexeme.len:
        return
    let body_start = first_nl + 1
    var last_nl = lexeme.len
    var found_last = false
    var k = lexeme.len
    while k > body_start:
        k -= 1
        if lexeme.byte_at(k) == '\n':
            last_nl = k
            found_last = true
            break
    if not found_last:
        return
    let body_end = last_nl + 1
    let margin = heredoc_margin(lexeme, body_start, body_end)
    var i = body_start
    while i < body_end:
        var line_nl = i
        while line_nl < body_end and lexeme.byte_at(line_nl) != '\n':
            line_nl += 1
        if is_blank_line(lexeme, i, line_nl):
            pass
        else:
            var j = i + margin
            while j < line_nl:
                print_escaped_byte(lexeme.byte_at(j))
                j += 1
        print_escaped_byte('\n')
        i = line_nl + 1


function print_string_literal(lexeme: str) -> void:
    stdio.print_char('"')
    if is_heredoc_lexeme(lexeme):
        print_heredoc_string_value(lexeme)
    else:
        print_inline_string_value(lexeme)
    stdio.print_char('"')


function print_float_literal(lexeme: str) -> void:
    var end = lexeme.len
    if end > 0:
        let last = lexeme.byte_at(end - 1)
        if last == 'f' or last == 'd' or last == 'F' or last == 'D':
            end -= 1

    var exp_pos = end
    var i: ptr_uint = 0
    while i < end:
        let b = lexeme.byte_at(i)
        if b == 'e' or b == 'E':
            exp_pos = i
            break
        i += 1

    var j: ptr_uint = 0
    while j < exp_pos:
        let b = lexeme.byte_at(j)
        if b != '_':
            stdio.print_char(b)
        j += 1

    if exp_pos < end:
        stdio.print_char('e')
        var ep = exp_pos + 1
        if ep < end:
            let s = lexeme.byte_at(ep)
            if s == '+' or s == '-':
                stdio.print_char(s)
                ep += 1
            else:
                stdio.print_char('+')
            var digits: int = 0
            var d = ep
            while d < end:
                let db = lexeme.byte_at(d)
                if db >= '0' and db <= '9':
                    digits += 1
                    d += 1
                else:
                    break
            if digits < 2:
                stdio.print_char('0')
            d = ep
            while d < end:
                let db = lexeme.byte_at(d)
                if db >= '0' and db <= '9':
                    stdio.print_char(db)
                    d += 1
                else:
                    break


function skip_quoted_string(lexeme: str, start: ptr_uint) -> ptr_uint:
    var i = start + 1
    while i < lexeme.len:
        let ch = lexeme.byte_at(i)
        if ch == '"':
            return i + 1
        if ch == '\\' and i + 1 < lexeme.len:
            i += 2
        else:
            i += 1
    return i


function find_closing_brace(lexeme: str, start: ptr_uint) -> ptr_uint:
    var depth: int = 1
    var i = start
    while i < lexeme.len:
        let ch = lexeme.byte_at(i)
        if ch == '"':
            i = skip_quoted_string(lexeme, i)
            continue
        if ch == '{':
            depth += 1
        else if ch == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return lexeme.len


function find_format_spec_colon(source: str) -> ptr_uint:
    var depth: int = 0
    var i: ptr_uint = 0
    while i < source.len:
        let ch = source.byte_at(i)
        if ch == '"':
            i = skip_quoted_string(source, i)
            continue
        if ch == '{':
            depth += 1
        else if ch == '}':
            depth -= 1
        else if depth == 0 and ch == ':':
            return i
        i += 1
    return 0


function emit_fstring_text_part(value: str) -> void:
    stdio.print_format("(:{} :kind :$text :value ")
    stdio_ext.print_quoted_str(value)
    stdio.print_char(')')


function emit_fstring_expr_part(source: str, format_spec: str, line: int, col: int) -> void:
    stdio.print_format("(:{} :kind :$expr :source ")
    stdio_ext.print_quoted_str(source)
    stdio.print_format(" :format_spec ")
    if format_spec.len > 0:
        stdio_ext.print_quoted_str(format_spec)
    else:
        stdio.print_format("nil")
    stdio.print_format(" :line %d :column %d)", line, col)


function build_heredoc_fstring_content(lexeme: str) -> string.String:
    var first_nl: ptr_uint = 0
    while first_nl < lexeme.len and lexeme.byte_at(first_nl) != '\n':
        first_nl += 1
    if first_nl >= lexeme.len:
        return string.String.create()
    let body_start = first_nl + 1
    var last_nl = lexeme.len
    var found_last = false
    var k = lexeme.len
    while k > body_start:
        k -= 1
        if lexeme.byte_at(k) == '\n':
            last_nl = k
            found_last = true
            break
    if not found_last:
        return string.String.create()
    let body_end = last_nl + 1
    let margin = heredoc_margin(lexeme, body_start, body_end)

    var content = string.String.create()
    var i = body_start
    while i < body_end:
        var line_nl = i
        while line_nl < body_end and lexeme.byte_at(line_nl) != '\n':
            line_nl += 1
        if is_blank_line(lexeme, i, line_nl):
            pass
        else:
            var j = i + margin
            while j < line_nl:
                content.push_byte(lexeme.byte_at(j))
                j += 1
        content.push_byte('\n')
        i = line_nl + 1
    return content


function advance_line_col(ch: ubyte, line: ref[int], col: ref[int],
                          base_col: int) -> void:
    unsafe:
        if ch == '\n':
            read(ptr[int]<-line) = read(ptr[int]<-line) + 1
            read(ptr[int]<-col) = base_col
        else:
            read(ptr[int]<-col) = read(ptr[int]<-col) + 1


function print_heredoc_fstring_parts(lexeme: str, tok_line: int, tok_col: int) -> void:
    var content_buf = build_heredoc_fstring_content(lexeme)
    defer content_buf.release()
    let content = content_buf.as_str()

    let margin = heredoc_margin(lexeme,
        body_start_of(lexeme),
        body_end_of(lexeme))
    let base_col = int<-(margin) + 1
    var line: int = tok_line
    var col: int = base_col
    let ccol = col

    var text_buf = string.String.create()
    defer text_buf.release()

    var i: ptr_uint = 0
    while i < content.len:
        let ch = content.byte_at(i)
        if ch == '#' and i + 1 < content.len and content.byte_at(i + 1) == '{':
            if text_buf.len() > 0:
                emit_fstring_text_part(text_buf.as_str())
                text_buf.clear()

            let expr_start = i + 2
            advance_line_col('#', ref_of(line), ref_of(col), base_col)
            advance_line_col('{', ref_of(line), ref_of(col), base_col)
            let expr_line = line
            let expr_col = col
            let expr_end = find_closing_brace(content, expr_start)

            let raw_source = content.slice(expr_start, expr_end - expr_start)
            let colon = find_format_spec_colon(raw_source)
            var fmt_spec: str = ""
            if colon > 0:
                let src_text = raw_source.slice(0, colon)
                fmt_spec = raw_source.slice(colon + 1, raw_source.len - colon - 1)
                emit_fstring_expr_part(src_text, fmt_spec, expr_line, expr_col)
            else:
                emit_fstring_expr_part(raw_source, "", expr_line, expr_col)

            var j = i
            while j <= expr_end:
                var cc = content.byte_at(j)
                advance_line_col(cc, ref_of(line), ref_of(col), base_col)
                j += 1
            i = expr_end + 1
            continue

        text_buf.push_byte(ch)
        advance_line_col(ch, ref_of(line), ref_of(col), base_col)
        i += 1

    if text_buf.len() > 0:
        emit_fstring_text_part(text_buf.as_str())


function body_start_of(lexeme: str) -> ptr_uint:
    var first_nl: ptr_uint = 0
    while first_nl < lexeme.len and lexeme.byte_at(first_nl) != '\n':
        first_nl += 1
    if first_nl >= lexeme.len:
        return lexeme.len
    return first_nl + 1


function body_end_of(lexeme: str) -> ptr_uint:
    let body_start = body_start_of(lexeme)
    if body_start >= lexeme.len:
        return lexeme.len
    var last_nl = lexeme.len
    var k = lexeme.len
    while k > body_start:
        k -= 1
        if lexeme.byte_at(k) == '\n':
            last_nl = k
            break
    return last_nl + 1


function print_inline_fstring_parts(lexeme: str, tok_line: int, tok_col: int) -> void:
    var i: ptr_uint = 2
    var col: int = tok_col + 2

    var text_buf = string.String.create()
    defer text_buf.release()

    while i < lexeme.len:
        let ch = lexeme.byte_at(i)
        if ch == '"':
            if text_buf.len() > 0:
                emit_fstring_text_part(text_buf.as_str())
            break
        if ch == '#' and i + 1 < lexeme.len and lexeme.byte_at(i + 1) == '{':
            if text_buf.len() > 0:
                emit_fstring_text_part(text_buf.as_str())
                text_buf.clear()

            let expr_start = i + 2
            let expr_col = col + 2
            let expr_end = find_closing_brace(lexeme, expr_start)

            let raw_source = lexeme.slice(expr_start, expr_end - expr_start)
            let colon = find_format_spec_colon(raw_source)
            var fmt_spec: str = ""
            if colon > 0:
                let src_text = raw_source.slice(0, colon)
                fmt_spec = raw_source.slice(colon + 1, raw_source.len - colon - 1)
                emit_fstring_expr_part(src_text, fmt_spec, tok_line, expr_col)
            else:
                emit_fstring_expr_part(raw_source, "", tok_line, expr_col)

            i = expr_end + 1
            col = tok_col + int<-(i)
            continue
        if ch == '\\' and i + 1 < lexeme.len:
            text_buf.push_byte(decode_str_escape(lexeme.byte_at(i + 1)))
            i += 2
            col += 2
            continue
        text_buf.push_byte(ch)
        i += 1
        col += 1


function print_fstring_literal(lexeme: str, tok_line: int, tok_col: int) -> void:
    stdio.print_char('[')
    if is_heredoc_lexeme(lexeme):
        print_heredoc_fstring_parts(lexeme, tok_line, tok_col)
    else:
        print_inline_fstring_parts(lexeme, tok_line, tok_col)
    stdio.print_char(']')
