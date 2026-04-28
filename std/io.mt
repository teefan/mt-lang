module std.io

import std.c.stdio as c
import std.mem.arena as arena

pub def print(text: str, scratch: ref[arena.Arena]) -> bool:
    let mark = value(scratch).mark()
    defer value(scratch).reset(mark)

    let c_text = value(scratch).to_cstr(text)
    let written = c.printf(c"%s", c_text)
    return written >= 0

pub def println(text: str, scratch: ref[arena.Arena]) -> bool:
    let mark = value(scratch).mark()
    defer value(scratch).reset(mark)

    let c_text = value(scratch).to_cstr(text)
    let written = c.printf(c"%s\n", c_text)
    return written >= 0
