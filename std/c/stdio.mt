external module std.c.stdio:
    include "stdio.h"

    opaque FILE = c"FILE"
    opaque va_list = c"va_list"

    const EOF: int = -1

    external function printf(format: cstr, ...) -> int
    external function fprintf(stream: FILE?, format: cstr, ...) -> int
    external function snprintf(text: ptr[char], maxlen: ptr_uint, format: cstr, ...) -> int
    external function vsnprintf(text: ptr[char], maxlen: ptr_uint, format: cstr, args: va_list) -> int
    external function vprintf(format: cstr, args: va_list) -> int
    external function vfprintf(stream: FILE?, format: cstr, args: va_list) -> int
    external function fopen(path: cstr, mode: cstr) -> FILE?
    external function fclose(stream: FILE?) -> int
    external function fgetc(stream: FILE?) -> int
    external function fputc(ch: int, stream: FILE?) -> int
    external function fgets(text: ptr[char], count: int, stream: FILE?) -> ptr[char]?
    external function fputs(text: cstr, stream: FILE?) -> int
    external function fread(buffer: ptr[void], element_size: ptr_uint, count: ptr_uint, stream: FILE?) -> ptr_uint
    external function fwrite(buffer: const_ptr[void], element_size: ptr_uint, count: ptr_uint, stream: FILE?) -> ptr_uint
    external function feof(stream: FILE?) -> int
    external function ferror(stream: FILE?) -> int
    external function clearerr(stream: FILE?) -> void
    external function fflush(stream: FILE?) -> int
