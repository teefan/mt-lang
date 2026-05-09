module std.time

import std.c.time as c
import std.mem.arena as arena
import std.status as status
import std.string as string

const format_buffer_capacity: ptr_uint = 128
const clock_buffer_capacity: ptr_uint = 7
const nanoseconds_per_second: long = 1000000000

public enum Error: ubyte
    invalid_time = 1
    output_too_large = 2

public type ClockId = c.clockid_t
public type Timespec = c.timespec

public const CLOCK_REALTIME: ClockId = c.CLOCK_REALTIME
public const CLOCK_MONOTONIC: ClockId = c.CLOCK_MONOTONIC

public struct ClockTime:
    hour: int
    minute: int
    second: int


public foreign function clock_getres(clock_id: ClockId, resolution: ptr[Timespec]) -> int = c.clock_getres
public foreign function clock_gettime(clock_id: ClockId, value: ptr[Timespec]) -> int = c.clock_gettime
public foreign function nanosleep(duration: const_ptr[Timespec], remaining: ptr[Timespec]?) -> int = c.nanosleep


public function timespec_to_nanoseconds(value: Timespec) -> long:
    return long<-value.tv_sec * nanoseconds_per_second + long<-value.tv_nsec


public function timespec_to_seconds(value: Timespec) -> double:
    return double<-value.tv_sec + double<-value.tv_nsec / double<-nanoseconds_per_second


public function monotonic_time() -> status.Status[Timespec, int]:
    var value = zero[Timespec]
    let code = clock_gettime(CLOCK_MONOTONIC, ptr_of(value))
    if code != 0:
        return status.Status[Timespec, int].err(error= code)
    return status.Status[Timespec, int].ok(value= value)


public function realtime_time() -> status.Status[Timespec, int]:
    var value = zero[Timespec]
    let code = clock_gettime(CLOCK_REALTIME, ptr_of(value))
    if code != 0:
        return status.Status[Timespec, int].err(error= code)
    return status.Status[Timespec, int].ok(value= value)


public function now_unix_seconds() -> long:
    var storage: c.time_t = 0
    let result = c.time(ptr_of(storage))
    return long<-result


function digit_value(digit: char) -> int:
    return int<-digit - 48


function two_digits(buffer: array[char, 7], index: int) -> int:
    return digit_value(buffer[index]) * 10 + digit_value(buffer[index + 1])


function clock_from_tm(time_info: ptr[c.tm]) -> status.Status[ClockTime, Error]:
    var buffer = zero[array[char, 7]]
    let written = c.strftime(ptr_of(buffer[0]), ulong<-clock_buffer_capacity, c"%H%M%S", time_info)
    if written != ptr_uint<-6:
        return status.Status[ClockTime, Error].err(error= Error.invalid_time)

    return status.Status[ClockTime, Error].ok(value= ClockTime(
        hour = two_digits(buffer, 0),
        minute = two_digits(buffer, 2),
        second = two_digits(buffer, 4),
    ))


public function hour_12(clock: ClockTime) -> int:
    let wrapped = clock.hour % 12
    if wrapped == 0:
        return 12
    return wrapped


public function clock_utc(timestamp: long) -> status.Status[ClockTime, Error]:
    var time_value: c.time_t = c.time_t<-timestamp
    let time_info = c.gmtime(ptr_of(time_value))
    return clock_from_tm(time_info)


public function clock_local(timestamp: long) -> status.Status[ClockTime, Error]:
    var time_value: c.time_t = c.time_t<-timestamp
    let time_info = c.localtime(ptr_of(time_value))
    return clock_from_tm(time_info)


public function local_clock() -> status.Status[ClockTime, Error]:
    return clock_local(now_unix_seconds())


function format_tm(time_info: ptr[c.tm], format: str, scratch: ref[arena.Arena]) -> status.Status[string.String, Error]:
    let mark = scratch.mark()
    defer scratch.reset(mark)

    let c_format = scratch.to_cstr(format)
    var buffer: array[char, 128]
    let written = c.strftime(ptr_of(buffer[0]), ulong<-format_buffer_capacity, c_format, time_info)
    if written == 0:
        return status.Status[string.String, Error].err(error= Error.output_too_large)

    var result = string.String.with_capacity(written)
    var index: ptr_uint = 0
    while index < written:
        unsafe: result.push_byte(ubyte<-read(ptr_of(buffer[0]) + index))
        index += 1

    return status.Status[string.String, Error].ok(value= result)


public function format_utc(timestamp: long, format: str, scratch: ref[arena.Arena]) -> status.Status[string.String, Error]:
    var time_value: c.time_t = c.time_t<-timestamp
    let time_info = c.gmtime(ptr_of(time_value))
    return format_tm(time_info, format, scratch)


public function format_local(timestamp: long, format: str, scratch: ref[arena.Arena]) -> status.Status[string.String, Error]:
    var time_value: c.time_t = c.time_t<-timestamp
    let time_info = c.localtime(ptr_of(time_value))
    return format_tm(time_info, format, scratch)
