extern module std.c.stdio:
    include "stdio.h"

    opaque FILE = c"FILE"
    opaque va_list = c"va_list"

    const EOF: int = -1

    extern def printf(format: cstr, ...) -> int
    extern def snprintf(text: ptr[char], maxlen: ptr_uint, format: cstr, ...) -> int
    extern def vprintf(format: cstr, args: va_list) -> int
    extern def fopen(path: cstr, mode: cstr) -> FILE?
    extern def fclose(stream: FILE?) -> int
    extern def fgetc(stream: FILE?) -> int
    extern def fputc(ch: int, stream: FILE?) -> int
    extern def ferror(stream: FILE?) -> int
    extern def fflush(stream: FILE?) -> int
