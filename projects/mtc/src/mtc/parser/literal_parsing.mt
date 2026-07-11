## Literal parsing — pure string-to-value conversion functions extracted from
## parser.mt.  All functions are leaf helpers: they take a lexeme string and
## return a parsed value, with no dependency on ParserState or token access.
##
## Mirrors `lib/milk_tea/core/parser/literal_parsing.rb` in the Ruby compiler.

import std.string as string
import std.str
import std.vec as vec
import std.mem.heap as heap_mod


const ZERO_BYTE_V: ubyte = '0'
const LOWER_X_V: ubyte = 'x'
const UPPER_X_V: ubyte = 'X'
const LOWER_B_V: ubyte = 'b'
const UPPER_B_V: ubyte = 'B'
const LOWER_E_V: ubyte = 'e'
const UPPER_E_V: ubyte = 'E'
const PLUS_BYTE_V: ubyte = '+'
const MINUS_BYTE_V: ubyte = '-'


public function parse_int_literal(lexeme: str) -> int:
    if lexeme.len == 0:
        return 0
    var pos: ptr_uint = 0
    var negative = false
    var value: int = 0

    unsafe:
        let first = ubyte<-read(lexeme.data)
        if first == MINUS_BYTE_V:
            negative = true
            pos = 1

        if pos + 2 < lexeme.len:
            let second = ubyte<-read(lexeme.data + pos)
            let third = ubyte<-read(lexeme.data + pos + 1)
            if second == ZERO_BYTE_V and (third == LOWER_X_V or third == UPPER_X_V):
                pos += 2
                while pos < lexeme.len:
                    let b = ubyte<-read(lexeme.data + pos)
                    if b == '_':
                        pos += 1
                        continue
                    value = value * 16
                    if b >= '0' and b <= '9':
                        value += int<-(b - '0')
                    else if b >= 'a' and b <= 'f':
                        value += int<-(b - 'a' + 10)
                    else if b >= 'A' and b <= 'F':
                        value += int<-(b - 'A' + 10)
                    else:
                        break
                    pos += 1
                if negative:
                    return -value
                return value

            if second == ZERO_BYTE_V and (third == LOWER_B_V or third == UPPER_B_V):
                pos += 2
                while pos < lexeme.len:
                    let b = ubyte<-read(lexeme.data + pos)
                    if b == '_':
                        pos += 1
                        continue
                    if b == '0':
                        value = value * 2
                    else if b == '1':
                        value = value * 2 + 1
                    else:
                        break
                    pos += 1
                if negative:
                    return -value
                return value

        while pos < lexeme.len:
            let b = ubyte<-read(lexeme.data + pos)
            if b == '_':
                pos += 1
                continue
            if b >= '0' and b <= '9':
                value = value * 10 + int<-(b - '0')
            else:
                break
            pos += 1

    if negative:
        return -value
    return value


public function parse_float_literal(lexeme: str) -> double:
    if lexeme.len == 0:
        return 0.0
    var pos: ptr_uint = 0
    var negative = false
    var exp_negative = false
    var int_part: int = 0
    var dec_part: int = 0
    var dec_div: int = 1
    var exp_part: int = 0
    var in_dec = false
    var in_exp = false

    unsafe:
        let first = ubyte<-read(lexeme.data)
        if first == MINUS_BYTE_V:
            negative = true
            pos = 1

        while pos < lexeme.len:
            let b = ubyte<-read(lexeme.data + pos)
            if b == '_':
                pos += 1
                continue
            if b == '.':
                in_dec = true
                pos += 1
                continue
            if b == LOWER_E_V or b == UPPER_E_V:
                in_exp = true
                pos += 1
                if pos < lexeme.len:
                    let sign = ubyte<-read(lexeme.data + pos)
                    if sign == MINUS_BYTE_V:
                        exp_negative = true
                        pos += 1
                    else if sign == PLUS_BYTE_V:
                        pos += 1
                continue
            if b >= '0' and b <= '9':
                let d = int<-(b - '0')
                if in_exp:
                    exp_part = exp_part * 10 + d
                else if in_dec:
                    dec_part = dec_part * 10 + d
                    dec_div *= 10
                else:
                    int_part = int_part * 10 + d
            else:
                break
            pos += 1

    var result: double = double<-(int_part)
    if dec_div > 1:
        result += double<-(dec_part) / double<-(dec_div)
    if exp_part != 0:
        var remaining = exp_part
        if exp_negative:
            while remaining > 0:
                result /= 10.0
                remaining -= 1
        else:
            while remaining > 0:
                result *= 10.0
                remaining -= 1
    if negative:
        return -result
    return result


public function parse_string_content(lexeme: str, is_cstring: bool) -> str:
    if lexeme.len < 2:
        return lexeme
    var body_start: ptr_uint = 1
    var body_stop = lexeme.len - 1
    if is_cstring:
        if lexeme.len < 3:
            return lexeme
        body_start = 2
    var buf = string.String.create()
    var i = body_start
    while i < body_stop:
        let b = lexeme.byte_at(i)
        if b == '\\' and i + 1 < body_stop:
            let esc = lexeme.byte_at(i + 1)
            buf.push_byte(decode_string_escape(esc))
            i += 2
        else:
            buf.push_byte(b)
            i += 1
    return buf.as_str()


public function decode_string_escape(ch: ubyte) -> ubyte:
    if ch == 'n':
        return '\n'
    if ch == 'r':
        return '\r'
    if ch == 't':
        return '\t'
    if ch == '0':
        return '\0'
    return ch


public function is_format_heredoc(lexeme: str) -> bool:
    if lexeme.len < 4:
        return false
    return lexeme.byte_at(0) == 102 and lexeme.byte_at(1) == 60 and lexeme.byte_at(2) == 60 and lexeme.byte_at(3) == 45


public function normalize_format_heredoc(lexeme: str) -> str:
    var header_nl: ptr_uint = 0
    var found_header = false
    while header_nl < lexeme.len:
        if lexeme.byte_at(header_nl) == 10:
            found_header = true
            break
        header_nl += 1
    if not found_header:
        return lexeme
    let body_start = header_nl + 1

    var last_nl = lexeme.len
    var found_last = false
    var k = lexeme.len
    while k > body_start:
        k -= 1
        if lexeme.byte_at(k) == 10:
            last_nl = k
            found_last = true
            break
    if not found_last:
        return lexeme

    var line_starts = vec.Vec[ptr_uint].create()
    var line_ends = vec.Vec[ptr_uint].create()
    var ls = body_start
    var p = body_start
    while p < last_nl:
        if lexeme.byte_at(p) == 10:
            line_starts.push(ls)
            line_ends.push(p)
            ls = p + 1
        p += 1
    line_starts.push(ls)
    line_ends.push(last_nl)

    var min_indent = heap_mod.ptr_uint_max
    var mi_set = false
    var li: ptr_uint = 0
    while li < line_starts.len():
        let a_ptr = line_starts.get(li) else:
            break
        let b_ptr = line_ends.get(li) else:
            break
        let a = unsafe: read(a_ptr)
        let b = unsafe: read(b_ptr)
        var sp = a
        while sp < b and lexeme.byte_at(sp) == 32:
            sp += 1
        if sp < b:
            let indent = sp - a
            if not mi_set or indent < min_indent:
                min_indent = indent
                mi_set = true
        li += 1
    if not mi_set:
        min_indent = 0

    var buf = string.String.create()
    buf.append("f\"")
    var idx: ptr_uint = 0
    while idx < line_starts.len():
        let a_ptr = line_starts.get(idx) else:
            break
        let b_ptr = line_ends.get(idx) else:
            break
        let a = unsafe: read(a_ptr)
        let b = unsafe: read(b_ptr)
        var cur = a
        var removed: ptr_uint = 0
        while cur < b and removed < min_indent and lexeme.byte_at(cur) == 32:
            cur += 1
            removed += 1
        while cur < b:
            let ch = lexeme.byte_at(cur)
            if ch == 35 and cur + 1 < b and lexeme.byte_at(cur + 1) == 123:
                buf.push_byte(35)
                buf.push_byte(123)
                cur += 2
                var depth: int = 1
                while cur < b and depth > 0:
                    let c2 = lexeme.byte_at(cur)
                    if c2 == 123:
                        depth += 1
                    else if c2 == 125:
                        depth -= 1
                    buf.push_byte(c2)
                    cur += 1
            else:
                append_escaped_byte(ref_of(buf), ch)
                cur += 1
        buf.append("\\n")
        idx += 1
    buf.append("\"")
    return buf.as_str()


public function append_escaped_byte(buf: ref[string.String], ch: ubyte) -> void:
    if ch == 34:
        buf.append("\\\"")
    else if ch == 92:
        buf.append("\\\\")
    else if ch == 9:
        buf.append("\\t")
    else if ch == 13:
        buf.append("\\r")
    else if ch == 0:
        buf.append("\\0")
    else:
        buf.push_byte(ch)


public function parse_char_value(lexeme: str) -> ubyte:
    if lexeme.len < 3:
        return 0
    var pos: ptr_uint = 1
    var value: ubyte = 0
    unsafe:
        let b = ubyte<-read(lexeme.data + pos)
        if b == '\\':
            pos += 1
            let esc = ubyte<-read(lexeme.data + pos)
            if esc == 'n':
                return 10
            else if esc == 'r':
                return 13
            else if esc == 't':
                return 9
            else if esc == '0':
                return 0
            else if esc == '\\':
                return 92
            else if esc == '\'':
                return 39
            else if esc == '\"':
                return 34
            else if esc == 'x':
                value = 0
                var hi = ubyte<-read(lexeme.data + pos + 1)
                var lo = ubyte<-read(lexeme.data + pos + 2)
                if hi >= '0' and hi <= '9':
                    value += (hi - '0') * 16
                else if hi >= 'a' and hi <= 'f':
                    value += (hi - 'a' + 10) * 16
                else if hi >= 'A' and hi <= 'F':
                    value += (hi - 'A' + 10) * 16
                if lo >= '0' and lo <= '9':
                    value += (lo - '0')
                else if lo >= 'a' and lo <= 'f':
                    value += (lo - 'a' + 10)
                else if lo >= 'A' and lo <= 'F':
                    value += (lo - 'A' + 10)
                return value
            return b
        return b
