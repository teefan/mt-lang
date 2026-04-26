module std.str

import std.mem.arena as arena

def utf8_continuation_byte(byte: u8) -> bool:
    return (byte & cast[u8](0xC0)) == cast[u8](0x80)

def utf8_boundary(text: str, index: usize) -> bool:
    if index == 0 or index == text.len:
        return true

    unsafe:
        let byte = cast[u8](deref(text.data + index))
        return not utf8_continuation_byte(byte)

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
        return value(space).to_cstr(this)
