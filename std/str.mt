module std.str

import std.ascii as ascii
import std.maybe as maybe
import std.mem.arena as arena
import std.span as sp


public function cstr_len(text: cstr) -> ptr_uint:
    var count: ptr_uint = 0
    unsafe:
        let data = ptr[char]<-text
        while read(data + count) != zero[char]:
            count += 1
    return count


public function cstr_as_str(text: cstr) -> str:
    unsafe:
        return str(data = ptr[char]<-text, len = cstr_len(text))


public function chars_as_str(text: ptr[char]) -> str:
    unsafe:
        return str(data = text, len = cstr_len(cstr<-text))


public function nullable_cstr_as_str(text: cstr?) -> maybe.Maybe[str]:
    if text == null:
        return maybe.Maybe[str].none

    return maybe.Maybe[str].some(value= cstr_as_str(cstr<-text))


public function as_byte_span(text: str) -> span[ubyte]:
    unsafe:
        return sp.from_ptr[ubyte](ptr[ubyte]<-text.data, text.len)


public function utf8_byte_span_as_str(bytes: span[ubyte]) -> maybe.Maybe[str]:
    unsafe:
        let borrowed = str(data = ptr[char]<-bytes.data, len = bytes.len)
        if not is_valid_utf8(borrowed):
            return maybe.Maybe[str].none

        return maybe.Maybe[str].some(value= borrowed)


public function utf8_continuation_byte(byte: ubyte) -> bool:
    return (byte & ubyte<-0xC0) == ubyte<-0x80


function utf8_boundary(text: str, index: ptr_uint) -> bool:
    if index == 0 or index == text.len:
        return true

    unsafe:
        let byte = ubyte<-read(text.data + index)
        return not utf8_continuation_byte(byte)


public function byte_at(text: str, index: ptr_uint) -> ubyte:
    if index >= text.len:
        panic(c"str.byte_at index out of bounds")

    unsafe:
        return ubyte<-read(text.data + index)


public function equal(left: str, right: str) -> bool:
    if left.len != right.len:
        return false

    var index: ptr_uint = 0
    while index < left.len:
        if byte_at(left, index) != byte_at(right, index):
            return false
        index += 1
    return true


public function starts_with(text: str, prefix: str) -> bool:
    if prefix.len > text.len:
        return false

    var index: ptr_uint = 0
    while index < prefix.len:
        if byte_at(text, index) != byte_at(prefix, index):
            return false
        index += 1
    return true


public function ends_with(text: str, suffix: str) -> bool:
    if suffix.len > text.len:
        return false

    let offset = text.len - suffix.len
    var index: ptr_uint = 0
    while index < suffix.len:
        if byte_at(text, offset + index) != byte_at(suffix, index):
            return false
        index += 1
    return true


public function find_byte(text: str, byte: ubyte) -> maybe.Maybe[ptr_uint]:
    var index: ptr_uint = 0
    while index < text.len:
        if byte_at(text, index) == byte:
            return maybe.Maybe[ptr_uint].some(value= index)
        index += 1
    return maybe.Maybe[ptr_uint].none


public function trim_ascii_whitespace(text: str) -> str:
    var start: ptr_uint = 0
    while start < text.len and ascii.is_space(byte_at(text, start)):
        start += 1

    var stop = text.len
    while stop > start and ascii.is_space(byte_at(text, stop - 1)):
        stop -= 1

    unsafe:
        return str(data = text.data + start, len = stop - start)


public function is_valid_utf8(text: str) -> bool:
    var index: ptr_uint = 0
    while index < text.len:
        let first = byte_at(text, index)
        if first < ubyte<-0x80:
            index += 1
        elif first >= ubyte<-0xC2 and first <= ubyte<-0xDF:
            if index + 1 >= text.len or not utf8_continuation_byte(byte_at(text, index + 1)):
                return false
            index += 2
        elif first == ubyte<-0xE0:
            if index + 2 >= text.len:
                return false
            let second = byte_at(text, index + 1)
            if second < ubyte<-0xA0 or second > ubyte<-0xBF or not utf8_continuation_byte(byte_at(text, index + 2)):
                return false
            index += 3
        elif first >= ubyte<-0xE1 and first <= ubyte<-0xEC:
            if index + 2 >= text.len or not utf8_continuation_byte(byte_at(text, index + 1)) or not utf8_continuation_byte(byte_at(text, index + 2)):
                return false
            index += 3
        elif first == ubyte<-0xED:
            if index + 2 >= text.len:
                return false
            let second = byte_at(text, index + 1)
            if second < ubyte<-0x80 or second > ubyte<-0x9F or not utf8_continuation_byte(byte_at(text, index + 2)):
                return false
            index += 3
        elif first >= ubyte<-0xEE and first <= ubyte<-0xEF:
            if index + 2 >= text.len or not utf8_continuation_byte(byte_at(text, index + 1)) or not utf8_continuation_byte(byte_at(text, index + 2)):
                return false
            index += 3
        elif first == ubyte<-0xF0:
            if index + 3 >= text.len:
                return false
            let second = byte_at(text, index + 1)
            if second < ubyte<-0x90 or second > ubyte<-0xBF or not utf8_continuation_byte(byte_at(text, index + 2)) or not utf8_continuation_byte(byte_at(text, index + 3)):
                return false
            index += 4
        elif first >= ubyte<-0xF1 and first <= ubyte<-0xF3:
            if index + 3 >= text.len or not utf8_continuation_byte(byte_at(text, index + 1)) or not utf8_continuation_byte(byte_at(text, index + 2)) or not utf8_continuation_byte(byte_at(text, index + 3)):
                return false
            index += 4
        elif first == ubyte<-0xF4:
            if index + 3 >= text.len:
                return false
            let second = byte_at(text, index + 1)
            if second < ubyte<-0x80 or second > ubyte<-0x8F or not utf8_continuation_byte(byte_at(text, index + 2)) or not utf8_continuation_byte(byte_at(text, index + 3)):
                return false
            index += 4
        else:
            return false

    return true

methods str:
    public function slice(start: ptr_uint, len: ptr_uint) -> str:
        if start > this.len:
            panic(c"str slice start out of bounds")
        if len > this.len - start:
            panic(c"str slice length out of bounds")

        let stop = start + len
        if not utf8_boundary(this, start):
            panic(c"str slice start must be a UTF-8 boundary")
        if not utf8_boundary(this, stop):
            panic(c"str slice end must be a UTF-8 boundary")

        unsafe:
            return str(data = this.data + start, len = len)


    public function to_cstr(space: ref[arena.Arena]) -> cstr:
        return space.to_cstr(this)
