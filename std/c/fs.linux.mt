external

link "uv"

include "fs_support.h"

struct mt_fs_string = c"mt_fs_string":
    data: ptr[char]?
    len: ptr_uint

struct mt_fs_entries = c"mt_fs_entries":
    data: ptr[ptr[char]]?
    lengths: ptr[ptr_uint]?
    count: ptr_uint

struct mt_fs_error = c"mt_fs_error":
    code: int
    message_data: ptr[char]?
    message_len: ptr_uint

struct mt_fs_metadata = c"mt_fs_metadata":
    kind: int
    mode: int
    size: ptr_uint
    modified_seconds: ptr_int
    modified_nanoseconds: ptr_int

external function mt_fs_path_kind(path: cstr) -> int
external function mt_fs_get_metadata(path: cstr, out out_metadata: mt_fs_metadata, out out_error: mt_fs_error) -> int
external function mt_fs_read_text(path: cstr, out out_text: mt_fs_string, out out_error: mt_fs_error) -> int
external function mt_fs_read_bytes(path: cstr, out out_bytes: mt_fs_string, out out_error: mt_fs_error) -> int
external function mt_fs_write_text(path: cstr, data: ptr[char]?, len: ptr_uint, out out_error: mt_fs_error) -> int
external function mt_fs_write_bytes(path: cstr, data: ptr[ubyte]?, len: ptr_uint, out out_error: mt_fs_error) -> int
external function mt_fs_create_directories(path: cstr, out out_error: mt_fs_error) -> int
external function mt_fs_current_directory(out out_text: mt_fs_string, out out_error: mt_fs_error) -> int
external function mt_fs_temporary_directory(out out_text: mt_fs_string, out out_error: mt_fs_error) -> int
external function mt_fs_canonicalize(path: cstr, out out_text: mt_fs_string, out out_error: mt_fs_error) -> int
external function mt_fs_create_temporary_directory(parent_dir: cstr, prefix: cstr, out out_path: mt_fs_string, out out_error: mt_fs_error) -> int
external function mt_fs_create_temporary_file(parent_dir: cstr, prefix: cstr, suffix: cstr, out out_path: mt_fs_string, out out_error: mt_fs_error) -> int
external function mt_fs_list_entries(path: cstr, out out_entries: mt_fs_entries, out out_error: mt_fs_error) -> int
external function mt_fs_remove(path: cstr, out out_error: mt_fs_error) -> int
external function mt_fs_rename(source_path: cstr, target_path: cstr, out out_error: mt_fs_error) -> int
external function mt_fs_set_permissions(path: cstr, mode: int, out out_error: mt_fs_error) -> int
