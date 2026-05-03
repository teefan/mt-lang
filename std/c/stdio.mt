extern module std.c.stdio:
    include "stdio.h"

    opaque FILE = c"FILE"
    opaque va_list = c"va_list"

    const EOF: i32 = -1

    extern def printf(format: cstr, ...) -> i32
    extern def snprintf(text: ptr[char], maxlen: usize, format: cstr, ...) -> i32

    extern def vprintf(format: cstr, args: va_list) -> i32

    extern def fopen(path: cstr, mode: cstr) -> FILE?
    extern def fclose(stream: FILE?) -> i32
    extern def fgetc(stream: FILE?) -> i32
    extern def fputc(ch: i32, stream: FILE?) -> i32
    extern def ferror(stream: FILE?) -> i32
    extern def fflush(stream: FILE?) -> i32