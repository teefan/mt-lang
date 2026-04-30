module std.str

import std.ascii as ascii
import std.mem.arena as arena
import std.option as option

pub def cstr_len(text: cstr) -> usize:
    var count: usize = 0
    unsafe:
        let data = ptr[char]<-text
        while read(data + count) != zero[char]():
            count += 1
    return count

pub def cstr_as_str(text: cstr) -> str:
    unsafe:
        return str(data = ptr[char]<-text, len = cstr_len(text))

pub def chars_as_str(text: ptr[char]) -> str:
    unsafe:
        return str(data = text, len = cstr_len(cstr<-text))

pub def utf8_continuation_byte(byte: u8) -> bool:
    return (byte & u8<-0xC0) == u8<-0x80

def utf8_boundary(text: str, index: usize) -> bool:
    if index == 0 or index == text.len:
        return true

    unsafe:
        let byte = u8<-read(text.data + index)
        return not utf8_continuation_byte(byte)

pub def byte_at(text: str, index: usize) -> u8:
    if index >= text.len:
        panic(c"str.byte_at index out of bounds")

    unsafe:
        return u8<-read(text.data + index)

pub def equal(left: str, right: str) -> bool:
    if left.len != right.len:
        return false

    var index: usize = 0
    while index < left.len:
        if byte_at(left, index) != byte_at(right, index):
            return false
        index += 1
    return true

pub def starts_with(text: str, prefix: str) -> bool:
    if prefix.len > text.len:
        return false

    var index: usize = 0
    while index < prefix.len:
        if byte_at(text, index) != byte_at(prefix, index):
            return false
        index += 1
    return true

pub def ends_with(text: str, suffix: str) -> bool:
    if suffix.len > text.len:
        return false

    let offset = text.len - suffix.len
    var index: usize = 0
    while index < suffix.len:
        if byte_at(text, offset + index) != byte_at(suffix, index):
            return false
        index += 1
    return true

pub def find_byte(text: str, byte: u8) -> option.Option[usize]:
    var index: usize = 0
    while index < text.len:
        if byte_at(text, index) == byte:
            return option.some[usize](index)
        index += 1
    return option.none[usize]()

pub def trim_ascii_whitespace(text: str) -> str:
    var start: usize = 0
    while start < text.len and ascii.is_space(byte_at(text, start)):
        start += 1

    var stop = text.len
    while stop > start and ascii.is_space(byte_at(text, stop - 1)):
        stop -= 1

    unsafe:
        return str(data = text.data + start, len = stop - start)

pub def is_valid_utf8(text: str) -> bool:
    var index: usize = 0
    while index < text.len:
        let first = byte_at(text, index)
        if first < u8<-0x80:
            index += 1
        elif first >= u8<-0xC2 and first <= u8<-0xDF:
            if index + 1 >= text.len or not utf8_continuation_byte(byte_at(text, index + 1)):
                return false
            index += 2
        elif first == u8<-0xE0:
            if index + 2 >= text.len:
                return false
            let second = byte_at(text, index + 1)
            if second < u8<-0xA0 or second > u8<-0xBF or not utf8_continuation_byte(byte_at(text, index + 2)):
                return false
            index += 3
        elif first >= u8<-0xE1 and first <= u8<-0xEC:
            if index + 2 >= text.len or not utf8_continuation_byte(byte_at(text, index + 1)) or not utf8_continuation_byte(byte_at(text, index + 2)):
                return false
            index += 3
        elif first == u8<-0xED:
            if index + 2 >= text.len:
                return false
            let second = byte_at(text, index + 1)
            if second < u8<-0x80 or second > u8<-0x9F or not utf8_continuation_byte(byte_at(text, index + 2)):
                return false
            index += 3
        elif first >= u8<-0xEE and first <= u8<-0xEF:
            if index + 2 >= text.len or not utf8_continuation_byte(byte_at(text, index + 1)) or not utf8_continuation_byte(byte_at(text, index + 2)):
                return false
            index += 3
        elif first == u8<-0xF0:
            if index + 3 >= text.len:
                return false
            let second = byte_at(text, index + 1)
            if second < u8<-0x90 or second > u8<-0xBF or not utf8_continuation_byte(byte_at(text, index + 2)) or not utf8_continuation_byte(byte_at(text, index + 3)):
                return false
            index += 4
        elif first >= u8<-0xF1 and first <= u8<-0xF3:
            if index + 3 >= text.len or not utf8_continuation_byte(byte_at(text, index + 1)) or not utf8_continuation_byte(byte_at(text, index + 2)) or not utf8_continuation_byte(byte_at(text, index + 3)):
                return false
            index += 4
        elif first == u8<-0xF4:
            if index + 3 >= text.len:
                return false
            let second = byte_at(text, index + 1)
            if second < u8<-0x80 or second > u8<-0x8F or not utf8_continuation_byte(byte_at(text, index + 2)) or not utf8_continuation_byte(byte_at(text, index + 3)):
                return false
            index += 4
        else:
            return false

    return true

methods str:
    pub def slice(start: usize, len: usize) -> str:
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

    pub def to_cstr(space: ref[arena.Arena]) -> cstr:
        return space.to_cstr(this)
