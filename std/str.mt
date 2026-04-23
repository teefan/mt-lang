module std.str

import std.mem.arena as arena

methods str:
    def slice(start: usize, len: usize) -> str:
        if start > this.len:
            panic(c"str slice start out of bounds")
        if len > this.len - start:
            panic(c"str slice length out of bounds")

        unsafe:
            return str(data = this.data + start, len = len)

    def to_cstr(space: ref[arena.Arena]) -> cstr:
        return value(space).to_cstr(this)
