import std.c.fs as c
import std.bytes as bytes
import std.mem.arena as arena
import std.mem.heap as heap
import std.maybe as maybe
import std.status as status
import std.str as text
import std.string as string
import std.vec as vec


const path_kind_none: int = 0
const path_kind_file: int = 1
const path_kind_directory: int = 2


public struct Error:
    code: int
    message: string.String


public struct Entries:
    values: vec.Vec[string.String]


function take_owned_string(data: ptr[char]?, len: ptr_uint) -> string.String:
    if data == null:
        if len != 0:
            fatal(c"fs.take_owned_string missing storage")

        return string.String.create()

    return unsafe: string.String(data = ptr[ubyte]<-data, len = len, capacity = len)


function take_owned_bytes(data: ptr[char]?, len: ptr_uint) -> bytes.Bytes:
    if data == null:
        if len != 0:
            fatal(c"fs.take_owned_bytes missing storage")

        return bytes.Bytes.empty()

    return unsafe: bytes.Bytes(data = ptr[ubyte]<-data, len = len)


function take_error(raw: c.mt_fs_error, fallback: str) -> Error:
    if raw.message_data == null and raw.message_len == 0:
        return Error(code = raw.code, message = string.String.from_str(fallback))

    return Error(code = raw.code, message = take_owned_string(raw.message_data, raw.message_len))


function validate_utf8_string(value: string.String, error_message: str) -> status.Status[string.String, Error]:
    match text.utf8_byte_span_as_str(unsafe: span[ubyte](data = ptr[ubyte]<-value.data, len = value.len)):
        maybe.Maybe.some:
            return status.Status[string.String, Error].ok(value= value)
        maybe.Maybe.none:
            var owned = value
            owned.release()
            return status.Status[string.String, Error].err(error= Error(code = -1, message = string.String.from_str(error_message)))


function release_string_values(values: ref[vec.Vec[string.String]]) -> void:
    var index: ptr_uint = 0
    while index < values.len():
        let value_ptr = values.get(index)
        if value_ptr == null:
            fatal(c"fs.release_string_values missing value")

        unsafe:
            var owned = read(value_ptr)
            owned.release()

        index += 1

    values.release()
    return


function path_kind(path: str) -> int:
    var storage = arena.create(path.len + 1)
    defer storage.release()
    return c.mt_fs_path_kind(storage.to_cstr(path))


methods Error:
    public editable function release() -> void:
        this.message.release()
        return


methods Entries:
    public function len() -> ptr_uint:
        return this.values.len()


    public function get(index: ptr_uint) -> maybe.Maybe[str]:
        let value_ptr = this.values.get(index)
        if value_ptr == null:
            return maybe.Maybe[str].none

        unsafe:
            return maybe.Maybe[str].some(value= read(value_ptr).as_str())


    public function contains(name: str) -> bool:
        var index: ptr_uint = 0
        while index < this.values.len():
            let value_ptr = this.values.get(index)
            if value_ptr == null:
                fatal(c"fs.Entries.contains missing value")

            unsafe:
                if read(value_ptr).as_str().equal(name):
                    return true

            index += 1

        return false


    public editable function release() -> void:
        release_string_values(ref_of(this.values))
        return


public function exists(path: str) -> bool:
    return path_kind(path) != path_kind_none


public function is_file(path: str) -> bool:
    return path_kind(path) == path_kind_file


public function is_directory(path: str) -> bool:
    return path_kind(path) == path_kind_directory


public function read_text(path: str) -> status.Status[string.String, Error]:
    var storage = arena.create(path.len + 1)
    defer storage.release()

    var raw_text = zero[c.mt_fs_string]
    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_read_text(storage.to_cstr(path), raw_text, raw_error)
    if status_code != 0:
        return status.Status[string.String, Error].err(error= take_error(raw_error, "fs read failed"))

    return validate_utf8_string(take_owned_string(raw_text.data, raw_text.len), "fs.read_text requires UTF-8 text")


public function read_bytes(path: str) -> status.Status[bytes.Bytes, Error]:
    var storage = arena.create(path.len + 1)
    defer storage.release()

    var raw_bytes = zero[c.mt_fs_string]
    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_read_bytes(storage.to_cstr(path), raw_bytes, raw_error)
    if status_code != 0:
        return status.Status[bytes.Bytes, Error].err(error= take_error(raw_error, "fs read bytes failed"))

    return status.Status[bytes.Bytes, Error].ok(value= take_owned_bytes(raw_bytes.data, raw_bytes.len))


public function write_text(path: str, content: str) -> status.Status[bool, Error]:
    var storage = arena.create(path.len + 1)
    defer storage.release()

    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_write_text(storage.to_cstr(path), content.data, content.len, raw_error)
    if status_code != 0:
        return status.Status[bool, Error].err(error= take_error(raw_error, "fs write failed"))

    return status.Status[bool, Error].ok(value= true)


public function write_bytes(path: str, content: span[ubyte]) -> status.Status[bool, Error]:
    var storage = arena.create(path.len + 1)
    defer storage.release()

    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_write_bytes(storage.to_cstr(path), content.data, content.len, raw_error)
    if status_code != 0:
        return status.Status[bool, Error].err(error= take_error(raw_error, "fs write bytes failed"))

    return status.Status[bool, Error].ok(value= true)


public function create_directories(path: str) -> status.Status[bool, Error]:
    var storage = arena.create(path.len + 1)
    defer storage.release()

    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_create_directories(storage.to_cstr(path), raw_error)
    if status_code != 0:
        return status.Status[bool, Error].err(error= take_error(raw_error, "fs create directories failed"))

    return status.Status[bool, Error].ok(value= true)


public function remove(path: str) -> status.Status[bool, Error]:
    var storage = arena.create(path.len + 1)
    defer storage.release()

    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_remove(storage.to_cstr(path), raw_error)
    if status_code != 0:
        return status.Status[bool, Error].err(error= take_error(raw_error, "fs remove failed"))

    return status.Status[bool, Error].ok(value= true)


public function rename(source_path: str, target_path: str) -> status.Status[bool, Error]:
    var source_storage = arena.create(source_path.len + 1)
    defer source_storage.release()
    var target_storage = arena.create(target_path.len + 1)
    defer target_storage.release()

    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_rename(source_storage.to_cstr(source_path), target_storage.to_cstr(target_path), raw_error)
    if status_code != 0:
        return status.Status[bool, Error].err(error= take_error(raw_error, "fs rename failed"))

    return status.Status[bool, Error].ok(value= true)


public function current_directory() -> status.Status[string.String, Error]:
    var raw_text = zero[c.mt_fs_string]
    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_current_directory(raw_text, raw_error)
    if status_code != 0:
        return status.Status[string.String, Error].err(error= take_error(raw_error, "fs current directory failed"))

    return validate_utf8_string(take_owned_string(raw_text.data, raw_text.len), "fs.current_directory requires UTF-8 text")


public function canonicalize(path: str) -> status.Status[string.String, Error]:
    var storage = arena.create(path.len + 1)
    defer storage.release()

    var raw_text = zero[c.mt_fs_string]
    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_canonicalize(storage.to_cstr(path), raw_text, raw_error)
    if status_code != 0:
        return status.Status[string.String, Error].err(error= take_error(raw_error, "fs canonicalize failed"))

    return validate_utf8_string(take_owned_string(raw_text.data, raw_text.len), "fs.canonicalize requires UTF-8 text")


public function list_entries(path: str) -> status.Status[Entries, Error]:
    var storage = arena.create(path.len + 1)
    defer storage.release()

    var raw_entries = zero[c.mt_fs_entries]
    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_list_entries(storage.to_cstr(path), raw_entries, raw_error)
    if status_code != 0:
        return status.Status[Entries, Error].err(error= take_error(raw_error, "fs list entries failed"))

    var values = vec.Vec[string.String].with_capacity(raw_entries.count)
    var index: ptr_uint = 0
    if raw_entries.count != 0 and (raw_entries.data == null or raw_entries.lengths == null):
        fatal(c"fs.list_entries missing storage")

    unsafe:
        let data_ptr = ptr[ptr[char]]<-raw_entries.data
        let length_ptr = ptr[ptr_uint]<-raw_entries.lengths
        while index < raw_entries.count:
            let owned = take_owned_string(read(data_ptr + index), read(length_ptr + index))
            match validate_utf8_string(owned, "fs.list_entries requires UTF-8 entry names"):
                status.Status.err as payload:
                    var remaining = index + 1
                    while remaining < raw_entries.count:
                        heap.release(read(data_ptr + remaining))
                        remaining += 1
                    heap.release(raw_entries.data)
                    heap.release(raw_entries.lengths)
                    release_string_values(ref_of(values))
                    return status.Status[Entries, Error].err(error= payload.error)
                status.Status.ok as validated_payload:
                    values.push(validated_payload.value)

            index += 1

    heap.release(raw_entries.data)
    heap.release(raw_entries.lengths)
    return status.Status[Entries, Error].ok(value= Entries(values = values))
