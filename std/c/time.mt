extern module std.c.time:
    include "time.h"

    type time_t = ptr_int

    opaque tm = c"struct tm"

    extern def time(timer: ptr[time_t]) -> time_t
    extern def localtime(timer: ptr[time_t]) -> ptr[tm]
    extern def gmtime(timer: ptr[time_t]) -> ptr[tm]
    extern def strftime(s: ptr[char], maxsize: ulong, format: cstr, tp: ptr[tm]) -> ptr_uint
