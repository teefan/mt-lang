extern module std.c.time:
    include "time_helpers.h"

    type time_t = ptr_int
    type clockid_t = int

    opaque tm = c"struct tm"

    struct timespec:
        tv_sec: ptr_int
        tv_nsec: ptr_int

    const CLOCK_REALTIME: clockid_t = 0
    const CLOCK_MONOTONIC: clockid_t = 1

    extern def time(timer: ptr[time_t]) -> time_t
    extern def localtime(timer: ptr[time_t]) -> ptr[tm]
    extern def gmtime(timer: ptr[time_t]) -> ptr[tm]
    extern def strftime(s: ptr[char], maxsize: ulong, format: cstr, tp: ptr[tm]) -> ptr_uint
    extern def clock_getres(clock_id: clockid_t, resolution: ptr[timespec]) -> int
    extern def clock_gettime(clock_id: clockid_t, value: ptr[timespec]) -> int
    extern def nanosleep(duration: const_ptr[timespec], remaining: ptr[timespec]?) -> int
