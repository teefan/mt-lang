## Text helpers shared by the debug dump sections: Ruby-compatible string
## inspection and the host's `value_repr` renderings.

import std.string as string


## `"lexeme"` with the escapes Ruby's `String#inspect` produces.
public function ruby_inspect(lexeme: str) -> string.String:
    return ruby_inspect_n(lexeme, lexeme.len)


## The same, for the first `limit` bytes of `lexeme`.
public function ruby_inspect_n(lexeme: str, limit: ptr_uint) -> string.String:
    var text = string.String.create()
    text.append("\"")
    var i: ptr_uint = 0
    while i < limit and i < lexeme.len:
        let code_byte = unsafe: read(lexeme.data + i)
        let code = ptr_uint<-code_byte
        if code == 92z:          # backslash
            text.append("\\\\")
        else if code == 34z:     # double quote
            text.append("\\\"")
        else if code == 10z:     # newline
            text.append("\\n")
        else if code == 9z:      # tab
            text.append("\\t")
        else if code == 13z:     # carriage return
            text.append("\\r")
        else if code < 32z or code == 127z:
            text.append("\\x")
            append_hex_byte(ref_of(text), code_byte)
        else:
            text.push_byte(ubyte<-code_byte)
        i += 1
    text.append("\"")
    return text


function append_hex_byte(target: ref[string.String], value_byte: char) -> void:
    let digits = "0123456789ABCDEF"
    let value = ptr_uint<-value_byte
    let high = value / 16z
    let low = value % 16z
    target.push_byte(ubyte<-unsafe: read(digits.data + high))
    target.push_byte(ubyte<-unsafe: read(digits.data + low))


## The host's `value_repr` for a String: Ruby inspect, truncated past 60
## characters with `...` after the first 57 (`val[0..56].inspect`).
public function ruby_string_value(value: str) -> string.String:
    if utf8_char_count(value) < 60:
        return ruby_inspect(value)
    let stop = utf8_prefix_bytes(value, 57)
    var truncated = ruby_inspect_n(value, stop)
    truncated.append("...")
    return truncated


## Number of UTF-8 characters in `text` (continuation bytes do not count).
public function utf8_char_count(text: str) -> ptr_uint:
    var count: ptr_uint = 0
    var i: ptr_uint = 0
    while i < text.len:
        let code_byte = ptr_uint<-unsafe: read(text.data + i)
        if (code_byte & 192z) != 128z:
            count += 1
        i += 1
    return count


## Byte offset just past the first `max_chars` characters of `text` (or the
## whole string when it is shorter).
public function utf8_prefix_bytes(text: str, max_chars: ptr_uint) -> ptr_uint:
    var chars: ptr_uint = 0
    var i: ptr_uint = 0
    while i < text.len:
        let code_byte = ptr_uint<-unsafe: read(text.data + i)
        if (code_byte & 192z) != 128z:
            if chars == max_chars:
                return i
            chars += 1
        i += 1
    return text.len


## `'─' * count`.
public function append_rule(target: ref[string.String], count: ptr_uint) -> void:
    var i: ptr_uint = 0
    while i < count:
        target.append("─")
        i += 1
