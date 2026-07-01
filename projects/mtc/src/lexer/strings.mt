import lexer.token as token_mod
import lexer.scanner
import std.str
import std.vec


function is_terminator(line: str, tag: str) -> bool:
    var idx: ptr_uint = 0
    while idx < line.len and (line.byte_at(idx) == ' ' or line.byte_at(idx) == '\r'):
        idx += 1

    if idx + tag.len > line.len:
        return false

    var ti: ptr_uint = 0
    while ti < tag.len:
        if line.byte_at(idx + ti) != tag.byte_at(ti):
            return false
        ti += 1

    idx += tag.len
    while idx < line.len:
        if line.byte_at(idx) != ' ' and line.byte_at(idx) != '\r':
            return false
        idx += 1

    return true


public function scan_heredoc(
    tokens: ref[vec.Vec[token_mod.Token]],
    source: str,
    heredoc_start: ptr_uint,
    start_col: ptr_uint,
    line_end: ptr_uint,
    tag_start: ptr_uint,
    line_num: ptr_uint,
    is_cstring: bool,
    is_fstring: bool,
) -> token_mod.ScanResult:
    var scan_end = line_end + 1
    var consumed: ptr_uint = 1
    var terminator_nl: ptr_uint = line_end

    var offset_local = tag_start
    while offset_local < source.len and scanner.is_alphanumeric(source.byte_at(offset_local)):
        offset_local += 1

    let tag_len = offset_local - tag_start
    if tag_len == 0:
        return token_mod.ScanResult(lines_consumed = 1, next_offset = line_end + 1)

    let tag = source.slice(tag_start, tag_len)

    while scan_end < source.len:
        var next_nl = scan_end
        while next_nl < source.len and source.byte_at(next_nl) != '\n':
            next_nl += 1

        let cur_line = source.slice(scan_end, next_nl - scan_end)
        consumed += 1

        if is_terminator(cur_line, tag):
            terminator_nl = next_nl
            scan_end = next_nl + 1
            break

        scan_end = next_nl + 1

    let lexeme = source.slice(heredoc_start, terminator_nl - heredoc_start)

    var kind: token_mod.TokenKind
    if is_fstring:
        kind = token_mod.TokenKind.fstring_literal
    else if is_cstring:
        kind = token_mod.TokenKind.cstring_literal
    else:
        kind = token_mod.TokenKind.string_literal

    token_mod.push_token(tokens, kind, lexeme, line_num, start_col, heredoc_start, terminator_nl)

    var has_nl: bool = terminator_nl < source.len and source.byte_at(terminator_nl) == '\n'
    var nl_w: ptr_uint = if has_nl: 1 else: 0
    token_mod.push_token(
        tokens,
        token_mod.TokenKind.newline,
        "\n",
        line_num + consumed - 1,
        1,
        terminator_nl,
        terminator_nl + nl_w,
    )

    return token_mod.ScanResult(lines_consumed = consumed, next_offset = scan_end)


public function try_concat_string_line(
    tokens: ref[vec.Vec[token_mod.Token]],
    source: str,
    prev_line_end: ptr_uint,
    base_indent: ptr_uint,
    line_num: ptr_uint,
) -> ptr_uint:
    var consumed: ptr_uint = 1
    var lookahead = prev_line_end + 1

    while true:
        if lookahead >= source.len:
            return consumed

        var next_nl = lookahead
        while next_nl < source.len and source.byte_at(next_nl) != '\n':
            next_nl += 1

        let next_line = source.slice(lookahead, next_nl - lookahead)

        var ls: ptr_uint = 0
        while ls < next_line.len and next_line.byte_at(ls) == ' ':
            ls += 1

        if ls <= base_indent:
            return consumed

        let rest = next_line.slice(ls, next_line.len - ls)
        if rest.len == 0:
            return consumed

        if rest.byte_at(0) == '#':
            return consumed

        let last_tok_ptr = tokens.last() else:
            return consumed

        let last_kind = unsafe: read(ptr[token_mod.Token]<-last_tok_ptr).kind

        if last_kind == token_mod.TokenKind.string_literal and rest.byte_at(0) == '"':
            let _idx = scan_string(tokens, rest, 0, line_num + consumed, lookahead + ls)
            consumed += 1
            lookahead = next_nl + 1
            continue

        if last_kind == token_mod.TokenKind.cstring_literal and rest.len >= 2 and rest.byte_at(0) == 'c' and rest.byte_at(1) == '"':
            let _idx = scan_cstring(tokens, rest, 0, line_num + consumed, lookahead + ls)
            consumed += 1
            lookahead = next_nl + 1
            continue

        return consumed


public function scan_string(
    tokens: ref[vec.Vec[token_mod.Token]],
    line: str,
    start: ptr_uint,
    line_num: ptr_uint,
    line_offset: ptr_uint,
) -> ptr_uint:
    var idx = start + 1
    while idx < line.len and line.byte_at(idx) != '"':
        if line.byte_at(idx) == '\\' and idx + 1 < line.len:
            idx += 1
        idx += 1

    if idx < line.len:
        idx += 1

    let lexeme = line.slice(start, idx - start)
    token_mod.push_token(tokens, token_mod.TokenKind.string_literal, lexeme, line_num, start + 1, line_offset + start, line_offset + idx)
    return idx


public function scan_cstring(
    tokens: ref[vec.Vec[token_mod.Token]],
    line: str,
    start: ptr_uint,
    line_num: ptr_uint,
    line_offset: ptr_uint,
) -> ptr_uint:
    var idx = start + 2
    while idx < line.len and line.byte_at(idx) != '"':
        if line.byte_at(idx) == '\\' and idx + 1 < line.len:
            idx += 1
        idx += 1

    if idx < line.len:
        idx += 1

    let lexeme = line.slice(start, idx - start)
    token_mod.push_token(tokens, token_mod.TokenKind.cstring_literal, lexeme, line_num, start + 1, line_offset + start, line_offset + idx)
    return idx


public function scan_char(
    tokens: ref[vec.Vec[token_mod.Token]],
    line: str,
    start: ptr_uint,
    line_num: ptr_uint,
    line_offset: ptr_uint,
) -> ptr_uint:
    var idx = start + 1
    if idx < line.len:
        let ch = line.byte_at(idx)
        if ch == '\\':
            idx += 1
            if idx < line.len and line.byte_at(idx) == 'x':
                idx += 1
                var digits: ptr_uint = 0
                while idx < line.len and scanner.is_hex_digit(line.byte_at(idx)) and digits < 2:
                    idx += 1
                    digits += 1
            else:
                idx += 1
        else:
            idx += 1

    if idx < line.len and line.byte_at(idx) == '\'':
        idx += 1

    let lexeme = line.slice(start, idx - start)
    token_mod.push_token(tokens, token_mod.TokenKind.char_literal, lexeme, line_num, start + 1, line_offset + start, line_offset + idx)
    return idx


function scan_format_interpolation_end(line: str, start: ptr_uint) -> ptr_uint:
    var idx = start
    var depth: ptr_uint = 1

    while idx < line.len:
        let ch = line.byte_at(idx)

        if ch == '"':
            idx += 1
            while idx < line.len and line.byte_at(idx) != '"':
                if line.byte_at(idx) == '\\' and idx + 1 < line.len:
                    idx += 1
                idx += 1
            if idx < line.len:
                idx += 1
            continue

        if ch == '{':
            depth += 1
            idx += 1
            continue

        if ch == '}':
            depth -= 1
            if depth == 0:
                return idx
            idx += 1
            continue

        idx += 1

    return line.len


public function scan_fstring(
    tokens: ref[vec.Vec[token_mod.Token]],
    line: str,
    start: ptr_uint,
    line_num: ptr_uint,
    line_offset: ptr_uint,
) -> ptr_uint:
    var idx = start + 2
    while idx < line.len and line.byte_at(idx) != '"':
        if line.byte_at(idx) == '\\' and idx + 1 < line.len:
            idx += 2
            continue

        if line.byte_at(idx) == '#' and idx + 1 < line.len and line.byte_at(idx + 1) == '{':
            idx = scan_format_interpolation_end(line, idx + 2) + 1
            continue

        idx += 1

    if idx < line.len:
        idx += 1

    let lexeme = line.slice(start, idx - start)
    token_mod.push_token(tokens, token_mod.TokenKind.fstring_literal, lexeme, line_num, start + 1, line_offset + start, line_offset + idx)
    return idx
