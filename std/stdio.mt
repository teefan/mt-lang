import std.c.stdio as c

public type File = c.FILE
public type VaList = c.va_list

public const EOF: int = c.EOF
public const SEEK_SET: int = c.SEEK_SET
public const SEEK_CUR: int = c.SEEK_CUR
public const SEEK_END: int = c.SEEK_END

public foreign function print(format: str as cstr, ...) -> int = c.printf
public foreign function print_to(stream: File?, format: str as cstr, ...) -> int = c.fprintf
public foreign function format_to(buffer: ptr[char], maxlen: ptr_uint, format: str as cstr, ...) -> int = c.snprintf
public foreign function format_to_with_args(buffer: ptr[char], maxlen: ptr_uint, format: str as cstr, args: VaList) -> int = c.vsnprintf
public foreign function print_with_args(format: str as cstr, args: VaList) -> int = c.vprintf
public foreign function print_to_with_args(stream: File?, format: str as cstr, args: VaList) -> int = c.vfprintf
public foreign function open(path: str as cstr, mode: str as cstr) -> File? = c.fopen
public foreign function temporary_file() -> File? = c.tmpfile
public foreign function close(stream: File?) -> int = c.fclose
public foreign function rename(from_path: str as cstr, to_path: str as cstr) -> int = c.rename
public foreign function remove(path: str as cstr) -> int = c.remove
public foreign function read_char(stream: File?) -> int = c.fgetc
public foreign function write_char(ch: int, stream: File?) -> int = c.fputc
public foreign function read_line(buffer: ptr[char], max_count: int, stream: File?) -> ptr[char]? = c.fgets
public foreign function print_string(text: str as cstr) -> int = c.puts
public foreign function write_string(text: str as cstr, stream: File?) -> int = c.fputs
public foreign function read_bytes(buffer: ptr[void], element_size: ptr_uint, count: ptr_uint, stream: File?) -> ptr_uint = c.fread
public foreign function write_bytes(buffer: const_ptr[void], element_size: ptr_uint, count: ptr_uint, stream: File?) -> ptr_uint = c.fwrite
public foreign function seek(stream: File?, offset: ptr_int, whence: int) -> int = c.fseek
public foreign function tell(stream: File?) -> ptr_int = c.ftell
public foreign function rewind(stream: File?) -> void = c.rewind
public foreign function end_of_file(stream: File?) -> int = c.feof
public foreign function error(stream: File?) -> int = c.ferror
public foreign function clear_error(stream: File?) -> void = c.clearerr
public foreign function flush(stream: File?) -> int = c.fflush
