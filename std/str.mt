import std.maybe as maybe
import std.mem.arena as arena


public function cstr_len(text: cstr) -> ptr_uint:
    var count: ptr_uint = 0
    unsafe:
        let data = ptr[char]<-text
        while read(data + count) != zero[char]:
            count += 1
    return count


public function cstr_as_str(text: cstr) -> str:
    return unsafe: str(data = ptr[char]<-text, len = cstr_len(text))


public function chars_as_str(text: ptr[char]) -> str:
    return unsafe: str(data = text, len = cstr_len(cstr<-text))


public function nullable_cstr_as_str(text: cstr?) -> maybe.Maybe[str]:
    if text == null:
        return maybe.Maybe[str].none

    return maybe.Maybe[str].some(value= cstr_as_str(cstr<-text))


public function as_byte_span(text: str) -> span[ubyte]:
    return unsafe: span[ubyte](data = ptr[ubyte]<-text.data, len = text.len)


public function utf8_byte_span_as_str(bytes: span[ubyte]) -> maybe.Maybe[str]:
    unsafe:
        let borrowed = str(data = ptr[char]<-bytes.data, len = bytes.len)
        if not borrowed.is_valid_utf8():
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


function is_ascii_space(byte: ubyte) -> bool:
    return byte == ubyte<-32 or byte == ubyte<-9 or byte == ubyte<-10 or byte == ubyte<-13 or byte == ubyte<-12


methods str:
    public function byte_at(index: ptr_uint) -> ubyte:
        if index >= this.len:
            fatal(c"str.byte_at index out of bounds")

        return unsafe: ubyte<-read(this.data + index)


    public function equal(right: str) -> bool:
        if this.len != right.len:
            return false

        var index: ptr_uint = 0
        while index < this.len:
            if this.byte_at(index) != right.byte_at(index):
                return false
            index += 1
        return true


    public function starts_with(prefix: str) -> bool:
        if prefix.len > this.len:
            return false

        var index: ptr_uint = 0
        while index < prefix.len:
            if this.byte_at(index) != prefix.byte_at(index):
                return false
            index += 1
        return true


    public function ends_with(suffix: str) -> bool:
        if suffix.len > this.len:
            return false

        let offset = this.len - suffix.len
        var index: ptr_uint = 0
        while index < suffix.len:
            if this.byte_at(offset + index) != suffix.byte_at(index):
                return false
            index += 1
        return true


    public function find_byte(byte: ubyte) -> maybe.Maybe[ptr_uint]:
        var index: ptr_uint = 0
        while index < this.len:
            if this.byte_at(index) == byte:
                return maybe.Maybe[ptr_uint].some(value= index)
            index += 1
        return maybe.Maybe[ptr_uint].none


    public function trim_ascii_whitespace() -> str:
        var start: ptr_uint = 0
        while start < this.len and is_ascii_space(this.byte_at(start)):
            start += 1

        var stop = this.len
        while stop > start and is_ascii_space(this.byte_at(stop - 1)):
            stop -= 1

        return unsafe: str(data = this.data + start, len = stop - start)


    public function is_valid_utf8() -> bool:
        var index: ptr_uint = 0
        while index < this.len:
            let first = this.byte_at(index)
            if first < ubyte<-0x80:
                index += 1
            elif first >= ubyte<-0xC2 and first <= ubyte<-0xDF:
                if index + 1 >= this.len or not utf8_continuation_byte(this.byte_at(index + 1)):
                    return false
                index += 2
            elif first == ubyte<-0xE0:
                if index + 2 >= this.len:
                    return false
                let second = this.byte_at(index + 1)
                if second < ubyte<-0xA0 or second > ubyte<-0xBF or not utf8_continuation_byte(this.byte_at(index + 2)):
                    return false
                index += 3
            elif first >= ubyte<-0xE1 and first <= ubyte<-0xEC:
                if index + 2 >= this.len or not utf8_continuation_byte(this.byte_at(index + 1)) or not utf8_continuation_byte(this.byte_at(index + 2)):
                    return false
                index += 3
            elif first == ubyte<-0xED:
                if index + 2 >= this.len:
                    return false
                let second = this.byte_at(index + 1)
                if second < ubyte<-0x80 or second > ubyte<-0x9F or not utf8_continuation_byte(this.byte_at(index + 2)):
                    return false
                index += 3
            elif first >= ubyte<-0xEE and first <= ubyte<-0xEF:
                if index + 2 >= this.len or not utf8_continuation_byte(this.byte_at(index + 1)) or not utf8_continuation_byte(this.byte_at(index + 2)):
                    return false
                index += 3
            elif first == ubyte<-0xF0:
                if index + 3 >= this.len:
                    return false
                let second = this.byte_at(index + 1)
                if second < ubyte<-0x90 or second > ubyte<-0xBF or not utf8_continuation_byte(this.byte_at(index + 2)) or not utf8_continuation_byte(this.byte_at(index + 3)):
                    return false
                index += 4
            elif first >= ubyte<-0xF1 and first <= ubyte<-0xF3:
                if index + 3 >= this.len or not utf8_continuation_byte(this.byte_at(index + 1)) or not utf8_continuation_byte(this.byte_at(index + 2)) or not utf8_continuation_byte(this.byte_at(index + 3)):
                    return false
                index += 4
            elif first == ubyte<-0xF4:
                if index + 3 >= this.len:
                    return false
                let second = this.byte_at(index + 1)
                if second < ubyte<-0x80 or second > ubyte<-0x8F or not utf8_continuation_byte(this.byte_at(index + 2)) or not utf8_continuation_byte(this.byte_at(index + 3)):
                    return false
                index += 4
            else:
                return false

        return true


    public function slice(start: ptr_uint, len: ptr_uint) -> str:
        if start > this.len:
            fatal(c"str slice start out of bounds")
        if len > this.len - start:
            fatal(c"str slice length out of bounds")

        let stop = start + len
        if not utf8_boundary(this, start):
            fatal(c"str slice start must be a UTF-8 boundary")
        if not utf8_boundary(this, stop):
            fatal(c"str slice end must be a UTF-8 boundary")

        return unsafe: str(data = this.data + start, len = len)


    public function to_cstr(space: ref[arena.Arena]) -> cstr:
        return space.to_cstr(this)
