module std.time

import std.c.time as c
import std.mem.arena as arena
import std.string as string

const format_buffer_capacity: ptr_uint = 128
const clock_buffer_capacity: ptr_uint = 7

pub enum Error: ubyte
    invalid_time = 1
    output_too_large = 2

pub struct ClockTime:
    hour: int
    minute: int
    second: int


pub def now_unix_seconds() -> long:
    var storage: c.time_t = 0
    let result = c.time(ptr_of(storage))
    return long<-result


def digit_value(digit: char) -> int:
    return int<-digit - 48


def two_digits(buffer: array[char, 7], index: int) -> int:
    return digit_value(buffer[index]) * 10 + digit_value(buffer[index + 1])


def clock_from_tm(time_info: ptr[c.tm]) -> Result[ClockTime, Error]:
    var buffer = zero[array[char, 7]]
    let written = c.strftime(ptr_of(buffer[0]), ulong<-clock_buffer_capacity, c"%H%M%S", time_info)
    if written != ptr_uint<-6:
        return err(Error.invalid_time)

    return ok(ClockTime(
        hour = two_digits(buffer, 0),
        minute = two_digits(buffer, 2),
        second = two_digits(buffer, 4),
    ))


pub def hour_12(clock: ClockTime) -> int:
    let wrapped = clock.hour % 12
    if wrapped == 0:
        return 12
    return wrapped


pub def clock_utc(timestamp: long) -> Result[ClockTime, Error]:
    var time_value: c.time_t = c.time_t<-timestamp
    let time_info = c.gmtime(ptr_of(time_value))
    return clock_from_tm(time_info)


pub def clock_local(timestamp: long) -> Result[ClockTime, Error]:
    var time_value: c.time_t = c.time_t<-timestamp
    let time_info = c.localtime(ptr_of(time_value))
    return clock_from_tm(time_info)


pub def local_clock() -> Result[ClockTime, Error]:
    return clock_local(now_unix_seconds())


def format_tm(time_info: ptr[c.tm], format: str, scratch: ref[arena.Arena]) -> Result[string.String, Error]:
    let mark = scratch.mark()
    defer scratch.reset(mark)

    let c_format = scratch.to_cstr(format)
    var buffer: array[char, 128]
    let written = c.strftime(ptr_of(buffer[0]), ulong<-format_buffer_capacity, c_format, time_info)
    if written == 0:
        return err(Error.output_too_large)

    var result = string.String.with_capacity(written)
    var index: ptr_uint = 0
    while index < written:
        unsafe:
            result.push_byte(ubyte<-read(ptr_of(buffer[0]) + index))
        index += 1

    return ok(result)


pub def format_utc(timestamp: long, format: str, scratch: ref[arena.Arena]) -> Result[string.String, Error]:
    var time_value: c.time_t = c.time_t<-timestamp
    let time_info = c.gmtime(ptr_of(time_value))
    return format_tm(time_info, format, scratch)


pub def format_local(timestamp: long, format: str, scratch: ref[arena.Arena]) -> Result[string.String, Error]:
    var time_value: c.time_t = c.time_t<-timestamp
    let time_info = c.localtime(ptr_of(time_value))
    return format_tm(time_info, format, scratch)
