module std.stdio

import std.c.stdio as c


public type File = c.FILE


public const EOF: int = c.EOF


public foreign function open(path: str as cstr, mode: str as cstr) -> File? = c.fopen
public foreign function close(stream: File?) -> int = c.fclose
public foreign function get_char(stream: File?) -> int = c.fgetc
public foreign function put_char(ch: int, stream: File?) -> int = c.fputc
public foreign function error(stream: File?) -> int = c.ferror
public foreign function flush(stream: File?) -> int = c.fflush
