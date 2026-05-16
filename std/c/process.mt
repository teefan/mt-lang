external

import std.c.libuv

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


external function mt_process_capture(file: cstr, args: ptr[ptr[char]], env: ptr[ptr[char]]?, cwd: cstr?, out result: mt_process_capture_result, out error: mt_process_error) -> int
external function mt_process_spawn_detached(file: cstr, args: ptr[ptr[char]], env: ptr[ptr[char]]?, cwd: cstr?, out pid: int, out error: mt_process_error) -> int
