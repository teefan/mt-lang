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


public function nullable_cstr_as_str(text: cstr?) -> Option[str]:
    if text == null:
        return Option[str].none

    return Option[str].some(value= cstr_as_str(text))


public function as_byte_span(text: str) -> span[ubyte]:
    return unsafe: span[ubyte](data = ptr[ubyte]<-text.data, len = text.len)


public function utf8_byte_span_as_str(bytes: span[ubyte]) -> Option[str]:
    unsafe:
        let borrowed = str(data = ptr[char]<-bytes.data, len = bytes.len)
        if not borrowed.is_valid_utf8():
            return Option[str].none

        return Option[str].some(value= borrowed)


public function utf8_continuation_byte(value: ubyte) -> bool:
    return (value & 0xC0) == 0x80


function utf8_boundary(text: str, index: ptr_uint) -> bool:
    if index == 0 or index == text.len:
        return true

    unsafe:
        let value = ubyte<-read(text.data + index)
        return not utf8_continuation_byte(value)


function is_ascii_space(value: ubyte) -> bool:
    return value == 32 or value == 9 or value == 10 or value == 13 or value == 12


extending str:
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


    public function find_byte(value: ubyte) -> Option[ptr_uint]:
        var index: ptr_uint = 0
        while index < this.len:
            if this.byte_at(index) == value:
                return Option[ptr_uint].some(value= index)
            index += 1
        return Option[ptr_uint].none


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
            if first < 0x80:
                index += 1
            else if first >= 0xC2 and first <= 0xDF:
                if index + 1 >= this.len or not utf8_continuation_byte(this.byte_at(index + 1)):
                    return false
                index += 2
            else if first == 0xE0:
                if index + 2 >= this.len:
                    return false
                let second = this.byte_at(index + 1)
                if second < 0xA0 or second > 0xBF or not utf8_continuation_byte(this.byte_at(index + 2)):
                    return false
                index += 3
            else if first >= 0xE1 and first <= 0xEC:
                if index + 2 >= this.len or not utf8_continuation_byte(this.byte_at(index + 1)) or not utf8_continuation_byte(this.byte_at(index + 2)):
                    return false
                index += 3
            else if first == 0xED:
                if index + 2 >= this.len:
                    return false
                let second = this.byte_at(index + 1)
                if second < 0x80 or second > 0x9F or not utf8_continuation_byte(this.byte_at(index + 2)):
                    return false
                index += 3
            else if first >= 0xEE and first <= 0xEF:
                if index + 2 >= this.len or not utf8_continuation_byte(this.byte_at(index + 1)) or not utf8_continuation_byte(this.byte_at(index + 2)):
                    return false
                index += 3
            else if first == 0xF0:
                if index + 3 >= this.len:
                    return false
                let second = this.byte_at(index + 1)
                if second < 0x90 or second > 0xBF or not utf8_continuation_byte(this.byte_at(index + 2)) or not utf8_continuation_byte(this.byte_at(index + 3)):
                    return false
                index += 4
            else if first >= 0xF1 and first <= 0xF3:
                if index + 3 >= this.len or not utf8_continuation_byte(this.byte_at(index + 1)) or not utf8_continuation_byte(this.byte_at(index + 2)) or not utf8_continuation_byte(this.byte_at(index + 3)):
                    return false
                index += 4
            else if first == 0xF4:
                if index + 3 >= this.len:
                    return false
                let second = this.byte_at(index + 1)
                if second < 0x80 or second > 0x8F or not utf8_continuation_byte(this.byte_at(index + 2)) or not utf8_continuation_byte(this.byte_at(index + 3)):
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
