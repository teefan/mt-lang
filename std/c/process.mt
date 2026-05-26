external


link "uv"
include "process_support.h"


struct mt_process_capture_result = c"mt_process_capture_result":
    stdout_data: ptr[char]?
    stdout_len: ptr_uint
    stderr_data: ptr[char]?
    stderr_len: ptr_uint
    exit_status: long
    term_signal: int


struct mt_process_error = c"mt_process_error":
    code: int
    message_data: ptr[char]?
    message_len: ptr_uint


struct mt_process_spawn_handle = c"mt_process_spawn_handle":
    pid: int
    stdin_fd: int
    stdout_fd: int
    stderr_fd: int


struct mt_process_pty_handle = c"mt_process_pty_handle":
    pid: int
    master_fd: int


struct mt_process_read_result = c"mt_process_read_result":
    ready: bool
    closed: bool
    data: ptr[char]?
    len: ptr_uint


struct mt_process_wait_result = c"mt_process_wait_result":
    ready: bool
    exit_status: long
    term_signal: int


external function mt_process_capture(file: cstr, args: ptr[ptr[char]], env: ptr[ptr[char]]?, cwd: cstr?, out result: mt_process_capture_result, out error: mt_process_error) -> int
external function mt_process_spawn_detached(file: cstr, args: ptr[ptr[char]], env: ptr[ptr[char]]?, cwd: cstr?, out pid: int, out error: mt_process_error) -> int
external function mt_process_spawn_interactive(file: cstr, args: ptr[ptr[char]], env: ptr[ptr[char]]?, cwd: cstr?, out handle: mt_process_spawn_handle, out error: mt_process_error) -> int
external function mt_process_spawn_pty(file: cstr, args: ptr[ptr[char]], env: ptr[ptr[char]]?, cwd: cstr?, columns: int, rows: int, out handle: mt_process_pty_handle, out error: mt_process_error) -> int
external function mt_process_read_fd(fd: int, timeout_ms: int, out result: mt_process_read_result, out error: mt_process_error) -> int
external function mt_process_write_fd(fd: int, data: const_ptr[char]?, len: ptr_uint, out written: ptr_uint, out error: mt_process_error) -> int
external function mt_process_close_fd(fd: int, out error: mt_process_error) -> int
external function mt_process_wait(pid: int, out result: mt_process_wait_result, out error: mt_process_error) -> int
external function mt_process_try_wait(pid: int, out result: mt_process_wait_result, out error: mt_process_error) -> int
external function mt_process_kill(pid: int, signal: int, out error: mt_process_error) -> int
external function mt_process_pty_resize(fd: int, columns: int, rows: int, out error: mt_process_error) -> int
