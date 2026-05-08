external module std.c.stdio:
    include "stdio.h"

    opaque FILE = c"FILE"
    opaque va_list = c"va_list"

    const EOF: int = -1

    external function printf(format: cstr, ...) -> int
    external function snprintf(text: ptr[char], maxlen: ptr_uint, format: cstr, ...) -> int
    external function vprintf(format: cstr, args: va_list) -> int
    external function fopen(path: cstr, mode: cstr) -> FILE?
    external function fclose(stream: FILE?) -> int
    external function fgetc(stream: FILE?) -> int
    external function fputc(ch: int, stream: FILE?) -> int
    external function ferror(stream: FILE?) -> int
    external function fflush(stream: FILE?) -> int
