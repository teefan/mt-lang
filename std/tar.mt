import std.bytes as bytes
import std.fs as fs
import std.gzip as gzip
import std.mem.heap as heap
import std.path as path_ops
import std.str as text
import std.string as string
import std.vec as vec

const block_size: ptr_uint = 512
const file_type_flag: ubyte = 48
const directory_type_flag: ubyte = 53
const zero_byte: ubyte = 0
const slash_byte: ubyte = 47
const space_byte: ubyte = 32

public struct Error:
    message: string.String

enum EntryKind: int
    file = 0
    directory = 1

struct UstarPath:
    prefix_start: ptr_uint
    prefix_len: ptr_uint
    name_start: ptr_uint
    name_len: ptr_uint

struct ParsedEntry:
    path: string.String
    kind: EntryKind
    mode: int
    size: ptr_uint
    data_offset: ptr_uint


function error_message(message: str) -> Error:
    return Error(message = string.String.from_str(message))


function take_vec_bytes(values: ref[vec.Vec[ubyte]]) -> bytes.Bytes:
    let data = values.data
    let len = values.len
    values.data = null
    values.len = 0
    values.capacity = 0

    if data == null:
        if len != 0:
            fatal(c"tar.take_vec_bytes missing storage")

        return bytes.Bytes.empty()

    return bytes.Bytes(data = data, len = len)


function take_fs_error(raw: fs.Error) -> Error:
    let message = string.String.from_str(raw.message.as_str())
    var owned = raw
    owned.release()
    return Error(message = message)


function take_gzip_error(raw: gzip.Error) -> Error:
    let message = string.String.from_str(raw.message.as_str())
    var owned = raw
    owned.release()
    return Error(message = message)


function release_string_values(values: ref[vec.Vec[string.String]]) -> void:
    var index: ptr_uint = 0
    while index < values.len():
        let value_ptr = values.get(index) else:
            fatal(c"tar.release_string_values missing value")

        unsafe:
            read(value_ptr).release()

        index += 1

    values.release()


function compare_text(left: str, right: str) -> int:
    var index: ptr_uint = 0
    var shared_len = left.len
    if right.len < shared_len:
        shared_len = right.len

    while index < shared_len:
        let left_value = left.byte_at(index)
        let right_value = right.byte_at(index)
        if left_value < right_value:
            return -1
        if left_value > right_value:
            return 1
        index += 1

    if left.len < right.len:
        return -1
    if left.len > right.len:
        return 1

    return 0


function sort_string_values(values: ref[vec.Vec[string.String]]) -> void:
    var index: ptr_uint = 1
    while index < values.len():
        var current = index
        while current > 0:
            let previous_ptr = values.get(current - 1) else:
                fatal(c"tar.sort_string_values missing previous value")
            let current_ptr = values.get(current) else:
                fatal(c"tar.sort_string_values missing current value")

            var should_swap = false
            unsafe:
                should_swap = compare_text(read(previous_ptr).as_str(), read(current_ptr).as_str()) > 0
            if should_swap:
                values.swap(current - 1, current)
            else:
                break

            current -= 1

        index += 1


function copy_sorted_entry_names(entries: fs.Entries, include_hidden: bool) -> Result[vec.Vec[string.String], Error]:
    var values = vec.Vec[string.String].create()

    var index: ptr_uint = 0
    while index < entries.len():
        match entries.get(index):
            Option.none:
                release_string_values(ref_of(values))
                return Result[
                    vec.Vec[string.String],
                    Error
                ].failure(error = error_message("tar list entries missing name"))
            Option.some as payload:
                if include_hidden or not payload.value.starts_with("."):
                    values.push(string.String.from_str(payload.value))

        index += 1

    sort_string_values(ref_of(values))
    return Result[vec.Vec[string.String], Error].success(value = values)


function append_zero_span(output: ref[vec.Vec[ubyte]], count: ptr_uint) -> void:
    if count == 0:
        return

    var zeroes = zero[array[ubyte, 512]]
    output.append_span(span[ubyte](data = ptr_of(zeroes[0]), len = count))


function append_padding(output: ref[vec.Vec[ubyte]], size_bytes: ptr_uint) -> void:
    let remainder = size_bytes % block_size
    if remainder == 0:
        return

    append_zero_span(output, block_size - remainder)


function append_end_blocks(output: ref[vec.Vec[ubyte]]) -> void:
    append_zero_span(output, block_size)
    append_zero_span(output, block_size)


function split_ustar_path(path: str) -> Result[UstarPath, Error]:
    if path.len == 0:
        return Result[UstarPath, Error].failure(error = error_message("tar entry path cannot be empty"))
    if path.len <= 100:
        return Result[UstarPath, Error].success(value = UstarPath(
            prefix_start = 0,
            prefix_len = 0,
            name_start = 0,
            name_len = path.len
        ))
    if path.len > 255:
        return Result[UstarPath, Error].failure(error = error_message("tar entry path exceeds ustar length limits"))

    var index = path.len
    while index > 0:
        index -= 1
        if path.byte_at(index) == slash_byte:
            let prefix_len = index
            let name_start = index + 1
            let name_len = path.len - name_start
            if prefix_len != 0 and prefix_len <= 155 and name_len <= 100:
                return Result[UstarPath, Error].success(value = UstarPath(
                    prefix_start = 0,
                    prefix_len = prefix_len,
                    name_start = name_start,
                    name_len = name_len
                ))

    return Result[
        UstarPath,
        Error
    ].failure(error = error_message("tar entry path cannot be represented in ustar format"))


function write_path_field(buffer: ptr[ubyte], offset: ptr_uint, value: str, start: ptr_uint, len: ptr_uint) -> void:
    var index: ptr_uint = 0
    while index < len:
        unsafe:
            read(buffer + offset + index) = value.byte_at(start + index)
        index += 1


function write_octal_digits(buffer: ptr[ubyte], offset: ptr_uint, digits_len: ptr_uint, value: ptr_uint) -> bool:
    var digits = zero[array[ubyte, 32]]
    var count: ptr_uint = 0
    var remaining = value

    if remaining == 0:
        digits[0] = 48
        count = 1
    else:
        while remaining != 0:
            if count >= 32:
                return false

            let digit = remaining % 8
            digits[count] = ubyte<-(48z + digit)
            remaining /= 8
            count += 1

    if count > digits_len:
        return false

    var index: ptr_uint = 0
    while index < digits_len:
        unsafe:
            read(buffer + offset + index) = 48
        index += 1

    index = 0
    var out_index = digits_len
    while index < count:
        out_index -= 1
        unsafe:
            read(buffer + offset + out_index) = digits[index]
        index += 1

    return true


function write_octal_field(buffer: ptr[ubyte], offset: ptr_uint, field_len: ptr_uint, value: ptr_uint) -> bool:
    if field_len < 2:
        return false

    if not write_octal_digits(buffer, offset, field_len - 1, value):
        return false

    unsafe:
        read(buffer + offset + field_len - 1) = zero_byte
    return true


function write_checksum_field(buffer: ptr[ubyte], offset: ptr_uint, value: ptr_uint) -> bool:
    if not write_octal_digits(buffer, offset, 6, value):
        return false

    unsafe:
        read(buffer + offset + 6) = zero_byte
        read(buffer + offset + 7) = space_byte
    return true


function header_checksum(buffer: ptr[ubyte]) -> ptr_uint:
    var sum: ptr_uint = 0
    var index: ptr_uint = 0
    while index < block_size:
        unsafe:
            sum += ptr_uint<-read(buffer + index)
        index += 1

    return sum


function append_header(
    output: ref[vec.Vec[ubyte]],
    archive_path: str,
    kind: EntryKind,
    mode: int,
    size_bytes: ptr_uint
) -> Result[bool, Error]:
    let parts = split_ustar_path(archive_path)?
    var header = zero[array[ubyte, 512]]
    let header_ptr = ptr_of(header[0])

    write_path_field(header_ptr, 0, archive_path, parts.name_start, parts.name_len)
    if not write_octal_field(header_ptr, 100, 8, ptr_uint<-(mode & 4095)):
        return Result[bool, Error].failure(error = error_message("tar mode exceeds field capacity"))
    if not write_octal_field(header_ptr, 108, 8, 0):
        return Result[bool, Error].failure(error = error_message("tar uid exceeds field capacity"))
    if not write_octal_field(header_ptr, 116, 8, 0):
        return Result[bool, Error].failure(error = error_message("tar gid exceeds field capacity"))

    var stored_size: ptr_uint = 0
    if kind == EntryKind.file:
        stored_size = size_bytes

    if not write_octal_field(header_ptr, 124, 12, stored_size):
        return Result[bool, Error].failure(error = error_message("tar size exceeds field capacity"))
    if not write_octal_field(header_ptr, 136, 12, 0):
        return Result[bool, Error].failure(error = error_message("tar mtime exceeds field capacity"))

    var checksum_index: ptr_uint = 148
    while checksum_index < 156:
        header[checksum_index] = space_byte
        checksum_index += 1

    if kind == EntryKind.directory:
        header[156] = directory_type_flag
    else:
        header[156] = file_type_flag

    header[257] = 117
    header[258] = 115
    header[259] = 116
    header[260] = 97
    header[261] = 114
    header[263] = 48
    header[264] = 48

    if parts.prefix_len != 0:
        write_path_field(header_ptr, 345, archive_path, parts.prefix_start, parts.prefix_len)

    if not write_checksum_field(header_ptr, 148, header_checksum(header_ptr)):
        return Result[bool, Error].failure(error = error_message("tar checksum exceeds field capacity"))

    output.append_array(header)
    return Result[bool, Error].success(value = true)


function append_file_entry(source_path: str, archive_path: str, output: ref[vec.Vec[ubyte]]) -> Result[bool, Error]:
    match fs.metadata(source_path):
        Result.failure as payload:
            return Result[bool, Error].failure(error = take_fs_error(payload.error))
        Result.success as metadata_payload:
            let metadata = metadata_payload.value
            match append_header(output, archive_path, EntryKind.file, metadata.mode, metadata.size):
                Result.failure as payload:
                    return Result[bool, Error].failure(error = payload.error)
                Result.success:
                    pass

    match fs.read_bytes(source_path):
        Result.failure as payload:
            return Result[bool, Error].failure(error = take_fs_error(payload.error))
        Result.success as payload:
            var data = payload.value
            defer data.release()
            output.append_span(data.as_span())
            append_padding(output, data.len)
            return Result[bool, Error].success(value = true)


function append_directory_tree(
    source_path: str,
    archive_path: str,
    include_hidden: bool,
    output: ref[vec.Vec[ubyte]]
) -> Result[bool, Error]:
    if archive_path.len != 0:
        match fs.metadata(source_path):
            Result.failure as payload:
                return Result[bool, Error].failure(error = take_fs_error(payload.error))
            Result.success as payload:
                let metadata = payload.value
                match append_header(output, archive_path, EntryKind.directory, metadata.mode, 0):
                    Result.failure as header_payload:
                        return Result[bool, Error].failure(error = header_payload.error)
                    Result.success:
                        pass

    match fs.list_entries(source_path):
        Result.failure as payload:
            return Result[bool, Error].failure(error = take_fs_error(payload.error))
        Result.success as payload:
            var entries = payload.value
            defer entries.release()

            match copy_sorted_entry_names(entries, include_hidden):
                Result.failure as names_payload:
                    return Result[bool, Error].failure(error = names_payload.error)
                Result.success as names_payload:
                    var names = names_payload.value
                    defer release_string_values(ref_of(names))

                    var index: ptr_uint = 0
                    while index < names.len():
                        let name_ptr = names.get(index) else:
                            return Result[bool, Error].failure(error = error_message("tar entry name missing"))

                        unsafe:
                            let child_name = read(name_ptr).as_str()
                            var child_source = path_ops.join(source_path, child_name)
                            var child_archive = string.String.create()
                            if archive_path.len == 0:
                                child_archive = string.String.from_str(child_name)
                            else:
                                child_archive = path_ops.join(archive_path, child_name)

                            if fs.is_directory(child_source.as_str()):
                                match append_directory_tree(
                                    child_source.as_str(),
                                    child_archive.as_str(),
                                    include_hidden,
                                    output
                                ):
                                    Result.failure as child_payload:
                                        child_source.release()
                                        child_archive.release()
                                        return Result[bool, Error].failure(error = child_payload.error)
                                    Result.success:
                                        pass
                            else if fs.is_file(child_source.as_str()):
                                match append_file_entry(child_source.as_str(), child_archive.as_str(), output):
                                    Result.failure as child_payload:
                                        child_source.release()
                                        child_archive.release()
                                        return Result[bool, Error].failure(error = child_payload.error)
                                    Result.success:
                                        pass

                            child_source.release()
                            child_archive.release()

                        index += 1

    return Result[bool, Error].success(value = true)


function block_is_zero(input: span[ubyte], offset: ptr_uint) -> bool:
    var index: ptr_uint = 0
    while index < block_size:
        unsafe:
            if read(input.data + offset + index) != 0:
                return false
        index += 1

    return true


function padded_size(size_bytes: ptr_uint) -> ptr_uint:
    let remainder = size_bytes % block_size
    if remainder == 0:
        return size_bytes

    return size_bytes + (block_size - remainder)


function parse_octal_field(input: span[ubyte], offset: ptr_uint, field_len: ptr_uint) -> Result[ptr_uint, Error]:
    var index: ptr_uint = 0
    while index < field_len:
        unsafe:
            let current = read(input.data + offset + index)
            if current == zero_byte or current == space_byte:
                index += 1
                continue
            break

    var value: ptr_uint = 0
    while index < field_len:
        unsafe:
            let current = read(input.data + offset + index)
            if current == zero_byte or current == space_byte:
                break
            if current < 48 or current > 55:
                return Result[
                    ptr_uint,
                    Error
                ].failure(error = error_message("tar numeric field contains non-octal digits"))
            let digit = ptr_uint<-(current - 48ub)
            if value > (heap.ptr_uint_max - digit) / 8:
                return Result[
                    ptr_uint,
                    Error
                ].failure(error = error_message("tar numeric field exceeds ptr_uint range"))
            value = value * 8 + digit

        index += 1

    return Result[ptr_uint, Error].success(value = value)


function read_text_field(input: span[ubyte], offset: ptr_uint, field_len: ptr_uint) -> Result[string.String, Error]:
    var used: ptr_uint = 0
    while used < field_len:
        unsafe:
            if read(input.data + offset + used) == zero_byte:
                break
        used += 1

    if used == 0:
        return Result[string.String, Error].success(value = string.String.create())

    let copied = heap.must_alloc[ubyte](used)
    unsafe:
        heap.copy_bytes(copied, input.data + offset, used)

    let owned = string.String(data = copied, len = used, capacity = used, owns_storage = true)
    match text.utf8_byte_span_as_str(span[ubyte](data = copied, len = used)):
        Option.some:
            return Result[string.String, Error].success(value = owned)
        Option.none:
            var invalid = owned
            invalid.release()
            return Result[string.String, Error].failure(error = error_message("tar text field must be valid UTF-8"))


function parse_entry(input: span[ubyte], offset: ptr_uint) -> Result[ParsedEntry, Error]:
    var name = read_text_field(input, offset + 0, 100)?
    defer name.release()

    var prefix = read_text_field(input, offset + 345, 155)?
    defer prefix.release()

    let name_text = name.as_str()
    if name_text.len == 0:
        return Result[ParsedEntry, Error].failure(error = error_message("tar entry missing name"))

    var full_path = string.String.create()
    if prefix.is_empty():
        full_path = string.String.from_str(name_text)
    else:
        full_path = path_ops.join(prefix.as_str(), name_text)

    match parse_octal_field(input, offset + 100, 8):
        Result.failure as payload:
            full_path.release()
            return Result[ParsedEntry, Error].failure(error = payload.error)
        Result.success as mode_payload:
            match parse_octal_field(input, offset + 124, 12):
                Result.failure as payload:
                    full_path.release()
                    return Result[ParsedEntry, Error].failure(error = payload.error)
                Result.success as size_payload:
                    var kind = EntryKind.file
                    unsafe:
                        let type_flag = read(input.data + offset + 156)
                        if type_flag == directory_type_flag:
                            kind = EntryKind.directory
                        else if type_flag != file_type_flag and type_flag != zero_byte:
                            full_path.release()
                            return Result[
                                ParsedEntry,
                                Error
                            ].failure(error = error_message("tar entry type is not supported"))

                    let data_offset = offset + block_size
                    if size_payload.value > input.len - data_offset:
                        full_path.release()
                        return Result[
                            ParsedEntry,
                            Error
                        ].failure(error = error_message("tar entry payload exceeds archive bounds"))

                    return Result[ParsedEntry, Error].success(value = ParsedEntry(
                        path = full_path,
                        kind = kind,
                        mode = int<-mode_payload.value,
                        size = size_payload.value,
                        data_offset = data_offset
                    ))


function checked_destination_path(destination_root: str, relative_path: str) -> Result[string.String, Error]:
    if relative_path.len == 0:
        return Result[string.String, Error].failure(error = error_message("tar extract path cannot be empty"))
    if path_ops.is_absolute(relative_path):
        return Result[string.String, Error].failure(error = error_message("tar extract path must be relative"))

    var destination_path = path_ops.join(destination_root, relative_path)
    match path_ops.relative_path(destination_path.as_str(), destination_root):
        Option.none:
            destination_path.release()
            return Result[
                string.String,
                Error
            ].failure(error = error_message("tar extract path escapes destination root"))
        Option.some as payload:
            var normalized = payload.value
            defer normalized.release()
            let normalized_path = normalized.as_str()
            let escapes_parent = normalized_path.len == 2 and normalized_path.byte_at(0) == 46 and normalized_path.byte_at(1) == 46
            if escapes_parent or normalized_path.starts_with("../"):
                destination_path.release()
                return Result[
                    string.String,
                    Error
                ].failure(error = error_message("tar extract path escapes destination root"))

    return Result[string.String, Error].success(value = destination_path)


extending Error:
    public editable function release() -> void:
        this.message.release()


extending ParsedEntry:
    public editable function release() -> void:
        this.path.release()


public function archive_directory(
    root_path: str,
    archive_root_name: str,
    include_hidden: bool
) -> Result[bytes.Bytes, Error]:
    if not fs.is_directory(root_path):
        return Result[
            bytes.Bytes,
            Error
        ].failure(error = error_message("tar.archive_directory requires a directory source"))
    if archive_root_name.len != 0 and path_ops.is_absolute(archive_root_name):
        return Result[bytes.Bytes, Error].failure(error = error_message("tar archive root name must be relative"))

    var output = vec.Vec[ubyte].create()
    match append_directory_tree(root_path, archive_root_name, include_hidden, ref_of(output)):
        Result.failure as payload:
            output.release()
            return Result[bytes.Bytes, Error].failure(error = payload.error)
        Result.success:
            pass

    append_end_blocks(ref_of(output))
    return Result[bytes.Bytes, Error].success(value = take_vec_bytes(ref_of(output)))


public function archive_directory_gzip(
    root_path: str,
    archive_root_name: str,
    include_hidden: bool
) -> Result[bytes.Bytes, Error]:
    match archive_directory(root_path, archive_root_name, include_hidden):
        Result.failure as payload:
            return Result[bytes.Bytes, Error].failure(error = payload.error)
        Result.success as payload:
            var archive = payload.value
            defer archive.release()
            match gzip.compress_bytes(archive.as_span()):
                Result.failure as gzip_payload:
                    return Result[bytes.Bytes, Error].failure(error = take_gzip_error(gzip_payload.error))
                Result.success as gzip_payload:
                    return Result[bytes.Bytes, Error].success(value = gzip_payload.value)


public function extract(archive: span[ubyte], destination_root: str) -> Result[bool, Error]:
    if archive.len % block_size != 0:
        return Result[bool, Error].failure(error = error_message("tar archive size must be a multiple of 512 bytes"))

    fs.create_directories(destination_root).map_err(take_fs_error)?

    var offset: ptr_uint = 0
    while offset < archive.len:
        if block_is_zero(archive, offset):
            return Result[bool, Error].success(value = true)

        var entry = parse_entry(archive, offset)?
        defer entry.release()

        var destination_path = checked_destination_path(destination_root, entry.path.as_str())?
        defer destination_path.release()

        if entry.kind == EntryKind.directory:
            fs.create_directories(destination_path.as_str()).map_err(take_fs_error)?

            fs.set_permissions(destination_path.as_str(), entry.mode).map_err(take_fs_error)?
        else:
            let parent = path_ops.dirname(destination_path.as_str())
            fs.create_directories(parent).map_err(take_fs_error)?

            let file_data = unsafe: span[ubyte](
                data = archive.data + entry.data_offset,
                len = entry.size
            )
            fs.write_bytes(destination_path.as_str(), file_data).map_err(take_fs_error)?

            fs.set_permissions(destination_path.as_str(), entry.mode).map_err(take_fs_error)?

        let entry_payload_size = padded_size(entry.size)
        if offset > heap.ptr_uint_max - block_size - entry_payload_size:
            return Result[bool, Error].failure(error = error_message("tar archive offset overflow"))

        offset += block_size + entry_payload_size

    return Result[bool, Error].success(value = true)


public function extract_gzip(archive: span[ubyte], destination_root: str) -> Result[bool, Error]:
    var decoded = gzip.decompress_bytes(archive).map_err(take_gzip_error)?
    defer decoded.release()
    return extract(decoded.as_span(), destination_root)
