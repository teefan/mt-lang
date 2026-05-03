module std.time

import std.c.time as c
import std.mem.arena as arena
import std.string as string

const format_buffer_capacity: usize = 128
const clock_buffer_capacity: usize = 7

pub enum Error: u8
    invalid_time = 1
    output_too_large = 2

pub struct ClockTime:
    hour: i32
    minute: i32
    second: i32

pub def now_unix_seconds() -> i64:
    var storage: c.time_t = 0
    let result = c.time(ptr_of(ref_of(storage)))
    return i64<-result

def digit_value(digit: char) -> i32:
    return i32<-digit - 48

def two_digits(buffer: array[char, 7], index: i32) -> i32:
    return digit_value(buffer[index]) * 10 + digit_value(buffer[index + 1])

def clock_from_tm(time_info: ptr[c.tm]) -> Result[ClockTime, Error]:
    var buffer = zero[array[char, 7]]()
    let written = c.strftime(ptr_of(ref_of(buffer[0])), u64<-clock_buffer_capacity, c"%H%M%S", time_info)
    if written != usize<-6:
        return err(Error.invalid_time)

    return ok(ClockTime(
        hour = two_digits(buffer, 0),
        minute = two_digits(buffer, 2),
        second = two_digits(buffer, 4),
    ))

pub def hour_12(clock: ClockTime) -> i32:
    let wrapped = clock.hour % 12
    if wrapped == 0:
        return 12
    return wrapped

pub def clock_utc(timestamp: i64) -> Result[ClockTime, Error]:
    var time_value: c.time_t = c.time_t<-timestamp
    let time_info = c.gmtime(ptr_of(ref_of(time_value)))
    return clock_from_tm(time_info)

pub def clock_local(timestamp: i64) -> Result[ClockTime, Error]:
    var time_value: c.time_t = c.time_t<-timestamp
    let time_info = c.localtime(ptr_of(ref_of(time_value)))
    return clock_from_tm(time_info)

pub def local_clock() -> Result[ClockTime, Error]:
    return clock_local(now_unix_seconds())

def format_tm(time_info: ptr[c.tm], format: str, scratch: ref[arena.Arena]) -> Result[string.String, Error]:
    let mark = scratch.mark()
    defer scratch.reset(mark)

    let c_format = scratch.to_cstr(format)
    var buffer: array[char, 128]
    let written = c.strftime(ptr_of(ref_of(buffer[0])), u64<-format_buffer_capacity, c_format, time_info)
    if written == 0:
        return err(Error.output_too_large)

    var result = string.String.with_capacity(written)
    var index: usize = 0
    while index < written:
        unsafe:
            result.push_byte(u8<-read(ptr_of(ref_of(buffer[0])) + index))
        index += 1

    return ok(result)

pub def format_utc(timestamp: i64, format: str, scratch: ref[arena.Arena]) -> Result[string.String, Error]:
    var time_value: c.time_t = c.time_t<-timestamp
    let time_info = c.gmtime(ptr_of(ref_of(time_value)))
    return format_tm(time_info, format, scratch)

pub def format_local(timestamp: i64, format: str, scratch: ref[arena.Arena]) -> Result[string.String, Error]:
    var time_value: c.time_t = c.time_t<-timestamp
    let time_info = c.localtime(ptr_of(ref_of(time_value)))
    return format_tm(time_info, format, scratch)