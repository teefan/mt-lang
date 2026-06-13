## std.encoding — UTF-8 validation, codepoint iteration, and character encoding helpers.

import std.str as text_ops

public function is_valid_utf8(text: str) -> bool:
    return text.is_valid_utf8()


public function utf8_codepoint_length(first_byte: ubyte) -> ptr_uint:
    if first_byte < 0x80:
        return 1
    if first_byte < 0xC2:
        return 0  # invalid continuation byte at start
    if first_byte <= 0xDF:
        return 2
    if first_byte <= 0xEF:
        return 3
    if first_byte <= 0xF4:
        return 4
    return 0  # invalid byte value


public function utf8_codepoint_count(text: str) -> ptr_uint:
    var count: ptr_uint = 0
    var index: ptr_uint = 0
    while index < text.len:
        let b = text.byte_at(index)
        let len = utf8_codepoint_length(b)
        if len == 0:
            index += 1
        else:
            index += len
        count += 1

    if index != text.len:
        return count
    return count


public function decode_utf8_codepoint(text: str, byte_offset: ptr_uint) -> Option[uint]:
    if byte_offset >= text.len:
        return Option[uint].none

    let b0 = text.byte_at(byte_offset)
    let len = utf8_codepoint_length(b0)
    if len == 0 or byte_offset + len > text.len:
        return Option[uint].none

    if len == 1:
        return Option[uint].some(value = uint<-(b0))

    var codepoint: uint = uint<-(b0)
    if len == 2:
        codepoint = codepoint & uint<-(0x1F)
    else if len == 3:
        codepoint = codepoint & uint<-(0x0F)
    else if len == 4:
        codepoint = codepoint & uint<-(0x07)
    var i: ptr_uint = 1
    while i < len:
        codepoint = (codepoint << 6) | uint<-(text.byte_at(byte_offset + i) & 0x3F)
        i += 1

    return Option[uint].some(value = codepoint)


public function utf8_overlong_check(text: str) -> bool:
    if not is_valid_utf8(text):
        return false

    var index: ptr_uint = 0
    while index < text.len:
        let b0 = text.byte_at(index)
        let len = utf8_codepoint_length(b0)
        if len == 0:
            index += 1
            continue

        if len > ptr_uint<-(text.len - index):
            return false

        if len == 3:
            let b1 = text.byte_at(index + 1)
            if b0 == 0xE0 and b1 < 0xA0:
                return false  # overlong 3-byte
        else if len == 4:
            let b1 = text.byte_at(index + 1)
            if b0 == 0xF0 and b1 < 0x90:
                return false  # overlong 4-byte

        index += len

    return true
