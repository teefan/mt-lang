extern module std.c.stdio:
    include "stdio.h"

    opaque va_list = c"va_list"

    extern def printf(format: cstr, ...) -> i32

    extern def vprintf(format: cstr, args: va_list) -> i32
