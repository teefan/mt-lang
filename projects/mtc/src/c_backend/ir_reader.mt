## IR JSON reader — recursive lazy parser for IR nodes.
##
## All values are `str` slices of the original JSON — no allocations.
## Caller never needs to release.

import std.str
import std.vec as vec_mod

public struct IrCursor:
    json: str

extending IrCursor:
    public static function from_json(json: str) -> IrCursor:
        return IrCursor(json = json)

    public function field_str(key: str) -> str:
        var raw = ir_field_raw(this.json, key)

        if raw.starts_with("\""):
            let end = raw.len
            if end >= 2:
                return raw.slice(1, end - 2)

        return raw

    public function field_int(key: str) -> int:
        let s = ir_field_raw(this.json, key)
        return str_to_int(s)

    public function field_bool(key: str) -> bool:
        let s = ir_field_raw(this.json, key)
        return s == "true"

    public function field_is_null(key: str) -> bool:
        let s = ir_field_raw(this.json, key)
        return s == "null"

    public function field_obj(key: str) -> IrCursor:
        let s = ir_field_raw(this.json, key)
        return IrCursor(json = s)

    public function field_array(key: str) -> str:
        return ir_field_raw(this.json, key)

# ── JSON field extraction ─────────────────────────────────────────────────

function ir_field_raw(json: str, key: str) -> str:
    var i: ptr_uint = 1

    while i < json.len:
        i = skip_ws(json, i)
        if i >= json.len or json.byte_at(i) == '}':
            break

        let fname_start = i
        let fname_str = parse_json_string_slice(json, ref_of(i))

        i = skip_ws(json, i)
        if i < json.len and json.byte_at(i) == ':':
            i += 1

        if fname_str == key:
            return parse_json_value_slice(json, ref_of(i))

        i = parse_json_value_skip(json, i)

        if i < json.len and json.byte_at(i) == ',':
            i += 1

    return ""

# ── JSON parsing primitives ───────────────────────────────────────────────

function skip_ws(s: str, i: ptr_uint) -> ptr_uint:
    var pos = i
    while pos < s.len:
        let ch = s.byte_at(pos)
        if ch != ' ' and ch != '\n' and ch != '\r' and ch != '\t':
            break
        pos += 1
    return pos

function parse_json_string_slice(s: str, i_ptr: ref[ptr_uint]) -> str:
    var i = skip_ws(s, unsafe: read(i_ptr))
    var start: ptr_uint = i

    if i < s.len and s.byte_at(i) == '"':
        i += 1
        while i < s.len:
            let ch = s.byte_at(i)
            if ch == '"':
                i += 1
                break
            else if ch == '\\':
                i += 2
            else:
                i += 1

    let len = if i >= start + 2: i - start - 2 else: 0
    let result = s.slice(start + 1, len)
    unsafe: read(i_ptr) = i
    return result

function parse_json_value_slice(s: str, i_ptr: ref[ptr_uint]) -> str:
    var i = skip_ws(s, unsafe: read(i_ptr))
    let start = i

    if i >= s.len:
        return ""

    let ch = s.byte_at(i)

    if ch == '{':
        i = find_matching_close(s, i, '{', '}')
        unsafe: read(i_ptr) = i
        return s.slice(start, i - start)

    if ch == '[':
        i = find_matching_close(s, i, '[', ']')
        unsafe: read(i_ptr) = i
        return s.slice(start, i - start)

    if ch == '"':
        i += 1
        while i < s.len:
            if s.byte_at(i) == '"':
                i += 1
                break
            else if s.byte_at(i) == '\\':
                i += 2
            else:
                i += 1
        unsafe: read(i_ptr) = i
        return s.slice(start, i - start)

    while i < s.len:
        let c = s.byte_at(i)
        if c == ',' or c == '}' or c == ']' or c == ' ' or c == '\n' or c == '\r' or c == '\t':
            break
        i += 1

    unsafe: read(i_ptr) = i
    return s.slice(start, i - start)

function parse_json_value_skip(s: str, start: ptr_uint) -> ptr_uint:
    var i = skip_ws(s, start)
    if i >= s.len:
        return i

    let ch = s.byte_at(i)

    if ch == '{':
        return find_matching_close(s, i, '{', '}')

    if ch == '[':
        return find_matching_close(s, i, '[', ']')

    if ch == '"':
        i += 1
        while i < s.len:
            if s.byte_at(i) == '"':
                i += 1
                break
            else if s.byte_at(i) == '\\':
                i += 2
            else:
                i += 1
        return i

    while i < s.len:
        let c = s.byte_at(i)
        if c == ',' or c == '}' or c == ']' or c == ' ' or c == '\n' or c == '\r' or c == '\t':
            break
        i += 1

    return i

function find_matching_close(s: str, start: ptr_uint, open_ch: ubyte, close_ch: ubyte) -> ptr_uint:
    var i = start
    if i >= s.len or s.byte_at(i) != open_ch:
        return start + 1

    var depth: ptr_uint = 1
    i += 1
    while i < s.len and depth > 0:
        let ch = s.byte_at(i)
        if ch == '"':
            i += 1
            while i < s.len:
                if s.byte_at(i) == '"':
                    i += 1
                    break
                else if s.byte_at(i) == '\\':
                    i += 1
                i += 1
        else:
            if ch == open_ch:
                depth += 1
            else if ch == close_ch:
                depth -= 1
            i += 1
    return i

function str_to_int(s: str) -> int:
    var result: int = 0
    var neg = false
    var i: ptr_uint = 0
    if i < s.len and s.byte_at(i) == '-':
        neg = true
        i += 1
    while i < s.len:
        let ch = s.byte_at(i)
        if ch >= '0' and ch <= '9':
            result = result * 10 + int<-(ch - 48)
        i += 1
    if neg:
        return -result
    return result
