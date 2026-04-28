module std.io

import std.c.stdio as c
import std.c.unistd as unistd
import std.mem.arena as arena

const stderr_fd: i32 = 2

pub def write_error(text: str) -> bool:
    if text.len == 0:
        return true

    unsafe:
        let written = unistd.write(stderr_fd, cast[ptr[void]](text.data), text.len)
        return written == cast[i64](text.len)

pub def write_error_line(text: str) -> bool:
    if not write_error(text):
        return false
    return write_error("\n")

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
