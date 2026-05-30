external

include "terminal_support.h"

struct mt_terminal_size = c"mt_terminal_size":
    width: int
    height: int

struct mt_terminal_error = c"mt_terminal_error":
    code: int
    message_data: ptr[char]?
    message_len: ptr_uint

external function mt_terminal_stdin_is_tty() -> bool
external function mt_terminal_stdout_is_tty() -> bool
external function mt_terminal_stderr_is_tty() -> bool
external function mt_terminal_get_size(out result: mt_terminal_size, out error: mt_terminal_error) -> int
external function mt_terminal_enter_raw_mode(out error: mt_terminal_error) -> int
external function mt_terminal_leave_raw_mode(out error: mt_terminal_error) -> int
external function mt_terminal_write_stdout(buffer: const_ptr[ubyte]?, len: ptr_uint, out out_written: ptr_uint, out error: mt_terminal_error) -> int
external function mt_terminal_write_stderr(buffer: const_ptr[ubyte]?, len: ptr_uint, out out_written: ptr_uint, out error: mt_terminal_error) -> int
external function mt_terminal_flush_stdout(out error: mt_terminal_error) -> int
external function mt_terminal_flush_stderr(out error: mt_terminal_error) -> int
external function mt_terminal_read_stdin(buffer: ptr[ubyte]?, capacity: ptr_uint, timeout_ms: int, out out_read: ptr_uint, out error: mt_terminal_error) -> int
