module std.stdio

import std.c.stdio as c


pub type File = c.FILE


pub const EOF: int = c.EOF


pub foreign def open(path: str as cstr, mode: str as cstr) -> File? = c.fopen
pub foreign def close(stream: File?) -> int = c.fclose
pub foreign def get_char(stream: File?) -> int = c.fgetc
pub foreign def put_char(ch: int, stream: File?) -> int = c.fputc
pub foreign def error(stream: File?) -> int = c.ferror
pub foreign def flush(stream: File?) -> int = c.fflush
