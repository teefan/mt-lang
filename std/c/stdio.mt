external

include "stdio.h"

opaque FILE = c"FILE"
opaque va_list = c"va_list"

const EOF: int = -1
const SEEK_SET: int = 0
const SEEK_CUR: int = 1
const SEEK_END: int = 2

external function printf(format: cstr, ...) -> int
external function fprintf(stream: FILE?, format: cstr, ...) -> int
external function snprintf(text: ptr[char], maxlen: ptr_uint, format: cstr, ...) -> int
external function vsnprintf(text: ptr[char], maxlen: ptr_uint, format: cstr, args: va_list) -> int
external function vprintf(format: cstr, args: va_list) -> int
external function vfprintf(stream: FILE?, format: cstr, args: va_list) -> int
external function fopen(path: cstr, mode: cstr) -> FILE?
external function tmpfile() -> FILE?
external function fclose(stream: FILE?) -> int
external function rename(old_path: cstr, new_path: cstr) -> int
external function remove(path: cstr) -> int
external function fgetc(stream: FILE?) -> int
external function fputc(ch: int, stream: FILE?) -> int
external function fgets(text: ptr[char], count: int, stream: FILE?) -> ptr[char]?
external function fputs(text: cstr, stream: FILE?) -> int
external function fread(buffer: ptr[void], element_size: ptr_uint, count: ptr_uint, stream: FILE?) -> ptr_uint
external function fwrite(buffer: const_ptr[void], element_size: ptr_uint, count: ptr_uint, stream: FILE?) -> ptr_uint
external function fseek(stream: FILE?, offset: ptr_int, whence: int) -> int
external function ftell(stream: FILE?) -> ptr_int
external function rewind(stream: FILE?) -> void
external function feof(stream: FILE?) -> int
external function ferror(stream: FILE?) -> int
external function clearerr(stream: FILE?) -> void
external function fflush(stream: FILE?) -> int
