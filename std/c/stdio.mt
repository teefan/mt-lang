extern module std.c.stdio:
    include "stdio.h"

    opaque __va_list_tag

    type va_list = array[__va_list_tag, 1]

    extern def printf(format: cstr, ...) -> i32

    extern def vprintf(format: cstr, args: ptr[__va_list_tag]) -> i32
