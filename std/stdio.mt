import std.c.stdio as c

public type File = c.FILE
public type VaList = c.va_list
public type FilePos = c.fpos_t

public const EOF: int = c.EOF
public const SEEK_SET: int = c.SEEK_SET
public const SEEK_CUR: int = c.SEEK_CUR
public const SEEK_END: int = c.SEEK_END

public const IO_FULLY_BUFFERED: int = c._IOFBF
public const IO_LINE_BUFFERED: int = c._IOLBF
public const IO_UNBUFFERED: int = c._IONBF

public const BUFFER_SIZE: int = c.BUFSIZ

# File Access & Lifecycle

public foreign function file_open(path: str as cstr, mode: str as cstr) -> File? = c.fopen
public foreign function file_reopen(path: str as cstr, mode: str as cstr, stream: File?) -> File? = c.freopen
public foreign function file_close(stream: File?) -> int = c.fclose
public foreign function file_flush(stream: File?) -> int = c.fflush
public foreign function file_set_buffer(stream: File?, buffer: ptr[char]) -> void = c.setbuf
public foreign function file_set_buffer_mode(stream: File?, buffer: ptr[char], mode: int, size: ptr_uint) -> int = c.setvbuf
public foreign function create_temp_file() -> File? = c.tmpfile
public foreign function gen_temp_name(buffer: ptr[char]) -> cstr = c.tmpnam
public foreign function file_rename(from_path: str as cstr, to_path: str as cstr) -> int = c.rename
public foreign function file_delete(path: str as cstr) -> int = c.remove

# Formatted Output

public foreign function file_print(stream: File?, format: str as cstr, ...) -> int = c.fprintf
public foreign function print_format(format: str as cstr, ...) -> int = c.printf
public foreign function str_format(buffer: ptr[char], format: str as cstr, ...) -> int = c.sprintf
public foreign function str_format_bounded(buffer: ptr[char], maxlen: ptr_uint, format: str as cstr, ...) -> int = c.snprintf

# Variadic Formatted Output

public foreign function file_print_args(stream: File?, format: str as cstr, args: VaList) -> int = c.vfprintf
public foreign function print_format_args(format: str as cstr, args: VaList) -> int = c.vprintf
public foreign function str_format_args(buffer: ptr[char], format: str as cstr, args: VaList) -> int = c.vsprintf
public foreign function str_format_bounded_args(buffer: ptr[char], maxlen: ptr_uint, format: str as cstr, args: VaList) -> int = c.vsnprintf

# Formatted Input

public foreign function file_read_format(stream: File?, format: str as cstr, ...) -> int = c.fscanf
public foreign function read_format(format: str as cstr, ...) -> int = c.scanf
public foreign function str_parse(buffer: cstr, format: str as cstr, ...) -> int = c.sscanf

# Variadic Formatted Input

public foreign function file_read_format_args(stream: File?, format: str as cstr, args: VaList) -> int = c.vfscanf
public foreign function read_format_args(format: str as cstr, args: VaList) -> int = c.vscanf
public foreign function str_parse_args(buffer: cstr, format: str as cstr, args: VaList) -> int = c.vsscanf

# Character Input & Output

public foreign function file_read_char(stream: File?) -> int = c.fgetc
public foreign function file_read_line(buffer: ptr[char], max_count: int, stream: File?) -> ptr[char]? = c.fgets
public foreign function file_write_char(ch: int, stream: File?) -> int = c.fputc
public foreign function file_write_str(text: str as cstr, stream: File?) -> int = c.fputs
public foreign function stream_read_char(stream: File?) -> int = c.getc
public foreign function read_char() -> int = c.getchar
public foreign function stream_write_char(ch: int, stream: File?) -> int = c.putc
public foreign function print_char(ch: int) -> int = c.putchar
public foreign function print_line(text: str as cstr) -> int = c.puts
public foreign function unget_char(ch: int, stream: File?) -> int = c.ungetc

# Direct/Binary Input & Output

public foreign function file_read_bytes(buffer: ptr[void], element_size: ptr_uint, count: ptr_uint, stream: File?) -> ptr_uint = c.fread
public foreign function file_write_bytes(buffer: const_ptr[void], element_size: ptr_uint, count: ptr_uint, stream: File?) -> ptr_uint = c.fwrite

# File Positioning

public foreign function file_get_pos_object(stream: File?, pos: ptr[FilePos]) -> int = c.fgetpos
public foreign function file_seek(stream: File?, offset: ptr_int, whence: int) -> int = c.fseek
public foreign function file_set_pos_object(stream: File?, pos: ptr[FilePos]) -> int = c.fsetpos
public foreign function file_get_pos(stream: File?) -> ptr_int = c.ftell
public foreign function file_rewind(stream: File?) -> void = c.rewind

# Error Handling

public foreign function file_clear_errors(stream: File?) -> void = c.clearerr
public foreign function file_is_eof(stream: File?) -> int = c.feof
public foreign function file_has_error(stream: File?) -> int = c.ferror
public foreign function print_system_error(prefix: str as cstr) -> void = c.perror
