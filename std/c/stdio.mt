external

include "stdio.h"

opaque FILE = c"FILE"
opaque va_list = c"va_list"
opaque fpos_t = c"fpos_t"

const EOF: int = -1
const SEEK_SET: int = 0
const SEEK_CUR: int = 1
const SEEK_END: int = 2

const _IOFBF: int = 0
const _IOLBF: int = 1
const _IONBF: int = 2

const BUFSIZ: int = 8192

# File Access & Lifecycle

external function fopen(path: cstr, mode: cstr) -> FILE?
external function freopen(path: cstr, mode: cstr, stream: FILE?) -> FILE?
external function fclose(stream: FILE?) -> int
external function fflush(stream: FILE?) -> int
external function setbuf(stream: FILE?, buffer: ptr[char]) -> void
external function setvbuf(stream: FILE?, buffer: ptr[char], mode: int, size: ptr_uint) -> int
external function tmpfile() -> FILE?
external function tmpnam(buffer: ptr[char]) -> cstr
external function rename(old_path: cstr, new_path: cstr) -> int
external function remove(path: cstr) -> int

# Formatted Output

external function fprintf(stream: FILE?, format: cstr, ...) -> int
external function printf(format: cstr, ...) -> int
external function sprintf(buffer: ptr[char], format: cstr, ...) -> int
external function snprintf(buffer: ptr[char], maxlen: ptr_uint, format: cstr, ...) -> int

# Variadic Formatted Output

external function vfprintf(stream: FILE?, format: cstr, args: va_list) -> int
external function vprintf(format: cstr, args: va_list) -> int
external function vsprintf(buffer: ptr[char], format: cstr, args: va_list) -> int
external function vsnprintf(buffer: ptr[char], maxlen: ptr_uint, format: cstr, args: va_list) -> int

# Formatted Input

external function fscanf(stream: FILE?, format: cstr, ...) -> int
external function scanf(format: cstr, ...) -> int
external function sscanf(buffer: cstr, format: cstr, ...) -> int

# Variadic Formatted Input

external function vfscanf(stream: FILE?, format: cstr, args: va_list) -> int
external function vscanf(format: cstr, args: va_list) -> int
external function vsscanf(buffer: cstr, format: cstr, args: va_list) -> int

# Character Input & Output

external function fgetc(stream: FILE?) -> int
external function fgets(buffer: ptr[char], count: int, stream: FILE?) -> ptr[char]?
external function fputc(ch: int, stream: FILE?) -> int
external function fputs(text: cstr, stream: FILE?) -> int
external function getc(stream: FILE?) -> int
external function getchar() -> int
external function putc(ch: int, stream: FILE?) -> int
external function putchar(ch: int) -> int
external function puts(text: cstr) -> int
external function ungetc(ch: int, stream: FILE?) -> int

# Direct/Binary Input & Output

external function fread(buffer: ptr[void], element_size: ptr_uint, count: ptr_uint, stream: FILE?) -> ptr_uint
external function fwrite(buffer: const_ptr[void], element_size: ptr_uint, count: ptr_uint, stream: FILE?) -> ptr_uint

# File Positioning

external function fgetpos(stream: FILE?, pos: ptr[fpos_t]) -> int
external function fseek(stream: FILE?, offset: ptr_int, whence: int) -> int
external function fsetpos(stream: FILE?, pos: ptr[fpos_t]) -> int
external function ftell(stream: FILE?) -> ptr_int
external function rewind(stream: FILE?) -> void

# Error Handling

external function clearerr(stream: FILE?) -> void
external function feof(stream: FILE?) -> int
external function ferror(stream: FILE?) -> int
external function perror(s: cstr) -> void
