import lexer.token as token_mod
import lexer.scanner
import std.str
import std.vec


function is_digit_or_underscore(ch: ubyte) -> bool:
    return scanner.is_digit(ch) or ch == '_'


function try_match_int_suffix(line: str, idx: ptr_uint) -> ptr_uint:
    var suffix_idx: ptr_uint = 0
    var suffixes = token_mod.int_suffixes
    while suffix_idx < token_mod.INT_SUFFIX_COUNT:
        let suffix = suffixes[suffix_idx]
        if idx + suffix.len <= line.len:
            var matched: bool = true
            var si: ptr_uint = 0
            while si < suffix.len:
                if line.byte_at(idx + si) != suffix.byte_at(si):
                    matched = false
                    break
                si += 1

            if matched:
                let after = idx + suffix.len
                if after >= line.len or not scanner.is_identifier_continuation(line.byte_at(after)):
                    return suffix.len

        suffix_idx += 1

    return 0


public function scan_number(
    tokens: ref[vec.Vec[token_mod.Token]],
    line: str,
    start: ptr_uint,
    line_num: ptr_uint,
    line_offset: ptr_uint,
) -> ptr_uint:
    var idx = start
    var is_floating: bool = false

    if line.byte_at(idx) == '0' and idx + 1 < line.len:
        let next_ch = line.byte_at(idx + 1)
        if next_ch == 'x' or next_ch == 'X':
            idx += 2
            while idx < line.len:
                let ch = line.byte_at(idx)
                if not scanner.is_hex_digit(ch) and ch != '_':
                    break
                idx += 1
            let suffix_len = try_match_int_suffix(line, idx)
            idx += suffix_len
            let lexeme = line.slice(start, idx - start)
            token_mod.push_token(tokens, token_mod.TokenKind.integer_literal, lexeme, line_num, start + 1, line_offset + start, line_offset + idx)
            return idx

        if next_ch == 'b' or next_ch == 'B':
            idx += 2
            while idx < line.len:
                let ch = line.byte_at(idx)
                if not scanner.is_bin_digit(ch) and ch != '_':
                    break
                idx += 1
            let suffix_len = try_match_int_suffix(line, idx)
            idx += suffix_len
            let lexeme = line.slice(start, idx - start)
            token_mod.push_token(tokens, token_mod.TokenKind.integer_literal, lexeme, line_num, start + 1, line_offset + start, line_offset + idx)
            return idx

    idx += 1
    while idx < line.len and is_digit_or_underscore(line.byte_at(idx)):
        idx += 1

    if idx < line.len and line.byte_at(idx) == '.' and idx + 1 < line.len and scanner.is_digit(line.byte_at(idx + 1)):
        is_floating = true
        idx += 1
        while idx < line.len and is_digit_or_underscore(line.byte_at(idx)):
            idx += 1

    if idx < line.len and (line.byte_at(idx) == 'e' or line.byte_at(idx) == 'E'):
        var sign_idx = idx + 1
        if sign_idx < line.len and (line.byte_at(sign_idx) == '+' or line.byte_at(sign_idx) == '-'):
            sign_idx += 1
        if sign_idx < line.len and scanner.is_digit(line.byte_at(sign_idx)):
            is_floating = true
            idx = sign_idx
            while idx < line.len and scanner.is_digit(line.byte_at(idx)):
                idx += 1

    if is_floating:
        if idx < line.len and (line.byte_at(idx) == 'f' or line.byte_at(idx) == 'd'):
            if idx + 1 >= line.len or not scanner.is_identifier_continuation(line.byte_at(idx + 1)):
                idx += 1
    else:
        let suffix_len = try_match_int_suffix(line, idx)
        idx += suffix_len

    let lexeme = line.slice(start, idx - start)
    let kind = if is_floating: token_mod.TokenKind.float_literal else: token_mod.TokenKind.integer_literal
    token_mod.push_token(tokens, kind, lexeme, line_num, start + 1, line_offset + start, line_offset + idx)
    return idx
