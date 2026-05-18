import std.c.fs as c
import std.bytes as bytes
import std.libc as libc
import std.mem.arena as arena
import std.mem.heap as heap
import std.path as path_ops
import std.str as text
import std.string as string
import std.vec as vec


const path_kind_none: int = 0
const path_kind_file: int = 1
const path_kind_directory: int = 2
const path_kind_other: int = 3
const temp_template_capacity: int = 4096


public struct Error:
    code: int
    message: string.String


public struct Entries:
    values: vec.Vec[string.String]


public enum MetadataKind: int
    none = 0
    file = 1
    directory = 2
    other = 3


public struct Metadata:
    kind: MetadataKind
    mode: int
    size: ptr_uint


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


function validate_utf8_string(text_value: string.String, error_message: str) -> Result[string.String, Error]:
    match text.utf8_byte_span_as_str(unsafe: span[ubyte](data = ptr[ubyte]<-text_value.data, len = text_value.len)):
        Option.some as _:
            return Result[string.String, Error].success(value= text_value)
        Option.none:
            var owned = text_value
            owned.release()
            return Result[string.String, Error].failure(error= Error(code = -1, message = string.String.from_str(error_message)))


function release_string_values(values: ref[vec.Vec[string.String]]) -> void:
    var index: ptr_uint = 0
    while index < values.len():
        let value_ptr = values.get(index) else:
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


function metadata_kind(raw_kind: int) -> MetadataKind:
    if raw_kind == path_kind_file:
        return MetadataKind.file

    if raw_kind == path_kind_directory:
        return MetadataKind.directory

    if raw_kind == path_kind_other:
        return MetadataKind.other

    return MetadataKind.none


extending Error:
    public mutable function release() -> void:
        this.message.release()
        return


extending Entries:
    public function len() -> ptr_uint:
        return this.values.len()


    public function get(index: ptr_uint) -> Option[str]:
        let value_ptr = this.values.get(index) else:
            return Option[str].none

        unsafe:
            return Option[str].some(value= read(value_ptr).as_str())


    public function contains(name: str) -> bool:
        var index: ptr_uint = 0
        while index < this.values.len():
            let value_ptr = this.values.get(index) else:
                fatal(c"fs.Entries.contains missing value")

            unsafe:
                if read(value_ptr).as_str().equal(name):
                    return true

            index += 1

        return false


    public mutable function release() -> void:
        release_string_values(ref_of(this.values))
        return


extending Metadata:
    public function is_file() -> bool:
        return this.kind == MetadataKind.file


    public function is_directory() -> bool:
        return this.kind == MetadataKind.directory


    public function is_other() -> bool:
        return this.kind == MetadataKind.other


public function exists(path: str) -> bool:
    return path_kind(path) != path_kind_none


public function is_file(path: str) -> bool:
    return path_kind(path) == path_kind_file


public function is_directory(path: str) -> bool:
    return path_kind(path) == path_kind_directory


public function read_text(path: str) -> Result[string.String, Error]:
    var storage = arena.create(path.len + 1)
    defer storage.release()

    var raw_text = zero[c.mt_fs_string]
    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_read_text(storage.to_cstr(path), raw_text, raw_error)
    if status_code != 0:
        return Result[string.String, Error].failure(error= take_error(raw_error, "fs read failed"))

    return validate_utf8_string(take_owned_string(raw_text.data, raw_text.len), "fs.read_text requires UTF-8 text")


public function read_bytes(path: str) -> Result[bytes.Bytes, Error]:
    var storage = arena.create(path.len + 1)
    defer storage.release()

    var raw_bytes = zero[c.mt_fs_string]
    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_read_bytes(storage.to_cstr(path), raw_bytes, raw_error)
    if status_code != 0:
        return Result[bytes.Bytes, Error].failure(error= take_error(raw_error, "fs read bytes failed"))

    return Result[bytes.Bytes, Error].success(value= take_owned_bytes(raw_bytes.data, raw_bytes.len))


public function metadata(path: str) -> Result[Metadata, Error]:
    var storage = arena.create(path.len + 1)
    defer storage.release()

    var raw_metadata = zero[c.mt_fs_metadata]
    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_get_metadata(storage.to_cstr(path), raw_metadata, raw_error)
    if status_code != 0:
        return Result[Metadata, Error].failure(error= take_error(raw_error, "fs metadata failed"))

    return Result[Metadata, Error].success(value= Metadata(
        kind = metadata_kind(raw_metadata.kind),
        mode = raw_metadata.mode,
        size = raw_metadata.size,
    ))


public function write_text(path: str, content: str) -> Result[bool, Error]:
    var storage = arena.create(path.len + 1)
    defer storage.release()

    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_write_text(storage.to_cstr(path), content.data, content.len, raw_error)
    if status_code != 0:
        return Result[bool, Error].failure(error= take_error(raw_error, "fs write failed"))

    return Result[bool, Error].success(value= true)


public function write_bytes(path: str, content: span[ubyte]) -> Result[bool, Error]:
    var storage = arena.create(path.len + 1)
    defer storage.release()

    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_write_bytes(storage.to_cstr(path), content.data, content.len, raw_error)
    if status_code != 0:
        return Result[bool, Error].failure(error= take_error(raw_error, "fs write bytes failed"))

    return Result[bool, Error].success(value= true)


public function set_permissions(path: str, mode: int) -> Result[bool, Error]:
    var storage = arena.create(path.len + 1)
    defer storage.release()

    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_set_permissions(storage.to_cstr(path), mode, raw_error)
    if status_code != 0:
        return Result[bool, Error].failure(error= take_error(raw_error, "fs set permissions failed"))

    return Result[bool, Error].success(value= true)


public function create_directories(path: str) -> Result[bool, Error]:
    var storage = arena.create(path.len + 1)
    defer storage.release()

    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_create_directories(storage.to_cstr(path), raw_error)
    if status_code != 0:
        return Result[bool, Error].failure(error= take_error(raw_error, "fs create directories failed"))

    return Result[bool, Error].success(value= true)


public function copy_entry(source_path: str, target_path: str) -> Result[bool, Error]:
    if is_file(source_path):
        match create_directories(path_ops.dirname(target_path)):
            Result.failure as payload:
                return Result[bool, Error].failure(error= payload.error)
            Result.success as ignored_payload:
                pass

        match read_bytes(source_path):
            Result.failure as payload:
                return Result[bool, Error].failure(error= payload.error)
            Result.success as payload:
                var data = payload.value
                defer data.release()
                return write_bytes(target_path, data.as_span())

    if is_directory(source_path):
        match create_directories(target_path):
            Result.failure as payload:
                return Result[bool, Error].failure(error= payload.error)
            Result.success as ignored_payload:
                pass

        match list_entries(source_path):
            Result.failure as payload:
                return Result[bool, Error].failure(error= payload.error)
            Result.success as payload:
                var entries = payload.value
                defer entries.release()

                var index: ptr_uint = 0
                while index < entries.len():
                    match entries.get(index):
                        Option.none:
                            return Result[bool, Error].failure(error= static_error("fs copy entry missing source entry"))
                        Option.some as entry_payload:
                            var child_source = path_ops.join(source_path, entry_payload.value)
                            var child_target = path_ops.join(target_path, entry_payload.value)
                            match copy_entry(child_source.as_str(), child_target.as_str()):
                                Result.failure as child_payload:
                                    child_source.release()
                                    child_target.release()
                                    return Result[bool, Error].failure(error= child_payload.error)
                                Result.success as ignored_child_payload:
                                    pass
                            child_source.release()
                            child_target.release()
                    index += 1

                return Result[bool, Error].success(value= true)

    if exists(source_path):
        return Result[bool, Error].failure(error= static_error("fs.copy_entry supports only regular files and directories"))

    return Result[bool, Error].failure(error= static_error("fs.copy_entry source does not exist"))


public function remove(path: str) -> Result[bool, Error]:
    var storage = arena.create(path.len + 1)
    defer storage.release()

    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_remove(storage.to_cstr(path), raw_error)
    if status_code != 0:
        return Result[bool, Error].failure(error= take_error(raw_error, "fs remove failed"))

    return Result[bool, Error].success(value= true)


public function remove_tree(path: str) -> Result[bool, Error]:
    if is_directory(path):
        match list_entries(path):
            Result.failure as payload:
                return Result[bool, Error].failure(error= payload.error)
            Result.success as payload:
                var entries = payload.value
                defer entries.release()

                var index: ptr_uint = 0
                while index < entries.len():
                    match entries.get(index):
                        Option.none:
                            return Result[bool, Error].failure(error= static_error("fs remove tree missing entry"))
                        Option.some as entry_payload:
                            var child_path = path_ops.join(path, entry_payload.value)
                            match remove_tree(child_path.as_str()):
                                Result.failure as child_payload:
                                    child_path.release()
                                    return Result[bool, Error].failure(error= child_payload.error)
                                Result.success as ignored_child_payload:
                                    pass
                            child_path.release()
                    index += 1

        return remove(path)

    if exists(path):
        return remove(path)

    return Result[bool, Error].success(value= true)


public function rename(source_path: str, target_path: str) -> Result[bool, Error]:
    var source_storage = arena.create(source_path.len + 1)
    defer source_storage.release()
    var target_storage = arena.create(target_path.len + 1)
    defer target_storage.release()

    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_rename(source_storage.to_cstr(source_path), target_storage.to_cstr(target_path), raw_error)
    if status_code != 0:
        return Result[bool, Error].failure(error= take_error(raw_error, "fs rename failed"))

    return Result[bool, Error].success(value= true)


public function current_directory() -> Result[string.String, Error]:
    var raw_text = zero[c.mt_fs_string]
    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_current_directory(raw_text, raw_error)
    if status_code != 0:
        return Result[string.String, Error].failure(error= take_error(raw_error, "fs current directory failed"))

    return validate_utf8_string(take_owned_string(raw_text.data, raw_text.len), "fs.current_directory requires UTF-8 text")


public function find_ancestor_containing(path: str, entry_name: str) -> Option[string.String]:
    var current = path_ops.normalize_separators(path_ops.dirname(path))
    if is_directory(path):
        current.release()
        current = path_ops.normalize_separators(path)

    while true:
        var candidate = path_ops.join(current.as_str(), entry_name)
        let found = exists(candidate.as_str())
        candidate.release()
        if found:
            return Option[string.String].some(value= current)

        let parent_text = path_ops.dirname(current.as_str())
        if parent_text == current.as_str():
            current.release()
            return Option[string.String].none

        var parent = string.String.from_str(parent_text)
        current.release()
        current = parent


function static_error(message: str) -> Error:
    return Error(code = -1, message = string.String.from_str(message))


public function temporary_directory() -> string.String:
    let configured = libc.get_environment_variable("TMPDIR")
    if configured != null:
        let configured_path = text.cstr_as_str(cstr<-configured)
        if configured_path.len != 0:
            return string.String.from_str(configured_path)

    return string.String.from_str("/tmp")


public function canonicalize(path: str) -> Result[string.String, Error]:
    var storage = arena.create(path.len + 1)
    defer storage.release()

    var raw_text = zero[c.mt_fs_string]
    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_canonicalize(storage.to_cstr(path), raw_text, raw_error)
    if status_code != 0:
        return Result[string.String, Error].failure(error= take_error(raw_error, "fs canonicalize failed"))

    return validate_utf8_string(take_owned_string(raw_text.data, raw_text.len), "fs.canonicalize requires UTF-8 text")


public function create_temporary_directory(parent_dir: str, prefix: str) -> Result[string.String, Error]:
    if prefix.len == 0:
        return Result[string.String, Error].failure(error= static_error("fs.create_temporary_directory requires a non-empty prefix"))

    var template_name = string.String.from_str(prefix)
    defer template_name.release()
    template_name.append("-XXXXXX")

    var template_path = path_ops.join(parent_dir, template_name.as_str())
    defer template_path.release()

    var buffer: str_buffer[temp_template_capacity]
    if template_path.len() > ptr_uint<-temp_template_capacity:
        return Result[string.String, Error].failure(error= static_error("fs.create_temporary_directory path exceeds buffer capacity"))

    buffer.assign(template_path.as_str())

    let created_path = libc.create_temp_directory(buffer) else:
        return Result[string.String, Error].failure(error= static_error("fs create temporary directory failed"))

    return Result[string.String, Error].success(value= string.String.from_str(text.cstr_as_str(created_path)))


public function create_temporary_directory_in_system_temp(prefix: str) -> Result[string.String, Error]:
    var root = temporary_directory()
    defer root.release()
    return create_temporary_directory(root.as_str(), prefix)


public function create_temporary_file(parent_dir: str, prefix: str, suffix: str) -> Result[string.String, Error]:
    if prefix.len == 0:
        return Result[string.String, Error].failure(error= static_error("fs.create_temporary_file requires a non-empty prefix"))

    var storage = arena.create(parent_dir.len + prefix.len + suffix.len + 3)
    defer storage.release()

    var raw_text = zero[c.mt_fs_string]
    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_create_temporary_file(storage.to_cstr(parent_dir), storage.to_cstr(prefix), storage.to_cstr(suffix), raw_text, raw_error)
    if status_code != 0:
        return Result[string.String, Error].failure(error= take_error(raw_error, "fs create temporary file failed"))

    return validate_utf8_string(take_owned_string(raw_text.data, raw_text.len), "fs.create_temporary_file requires UTF-8 text")


public function create_temporary_file_in_system_temp(prefix: str, suffix: str) -> Result[string.String, Error]:
    var root = temporary_directory()
    defer root.release()
    return create_temporary_file(root.as_str(), prefix, suffix)


public function list_entries(path: str) -> Result[Entries, Error]:
    var storage = arena.create(path.len + 1)
    defer storage.release()

    var raw_entries = zero[c.mt_fs_entries]
    var raw_error = zero[c.mt_fs_error]
    let status_code = c.mt_fs_list_entries(storage.to_cstr(path), raw_entries, raw_error)
    if status_code != 0:
        return Result[Entries, Error].failure(error= take_error(raw_error, "fs list entries failed"))

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
                Result.failure as payload:
                    var remaining = index + 1
                    while remaining < raw_entries.count:
                        heap.release(read(data_ptr + remaining))
                        remaining += 1
                    heap.release(raw_entries.data)
                    heap.release(raw_entries.lengths)
                    release_string_values(ref_of(values))
                    return Result[Entries, Error].failure(error= payload.error)
                Result.success as validated_payload:
                    values.push(validated_payload.value)

            index += 1

    heap.release(raw_entries.data)
    heap.release(raw_entries.lengths)
    return Result[Entries, Error].success(value= Entries(values = values))
