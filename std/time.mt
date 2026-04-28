module std.time

import std.c.time as c
import std.mem.arena as arena
import std.string as string

const format_buffer_capacity: usize = 128

pub enum Error: u8
    invalid_time = 1
    output_too_large = 2

pub def now_unix_seconds() -> i64:
    var storage: c.time_t = 0
    let result = c.time(raw(addr(storage)))
    return cast[i64](result)

def format_tm(time_info: ptr[c.tm], format: str, scratch: ref[arena.Arena]) -> Result[string.String, Error]:
    let mark = value(scratch).mark()
    defer value(scratch).reset(mark)

    let c_format = value(scratch).to_cstr(format)
    var buffer: array[char, 128]
    let written = c.strftime(raw(addr(buffer[0])), cast[u64](format_buffer_capacity), c_format, time_info)
    if written == 0:
        return err(Error.output_too_large)

    var result = string.with_capacity(written)
    var index: usize = 0
    while index < written:
        unsafe:
            string.push_byte(addr(result), cast[u8](deref(raw(addr(buffer[0])) + index)))
        index += 1

    return ok(result)

pub def format_utc(timestamp: i64, format: str, scratch: ref[arena.Arena]) -> Result[string.String, Error]:
    var time_value: c.time_t = timestamp
    let time_info = c.gmtime(raw(addr(time_value)))
    return format_tm(time_info, format, scratch)

pub def format_local(timestamp: i64, format: str, scratch: ref[arena.Arena]) -> Result[string.String, Error]:
    var time_value: c.time_t = timestamp
    let time_info = c.localtime(raw(addr(time_value)))
    return format_tm(time_info, format, scratch)
