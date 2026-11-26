import std.bytes as bytes
import std.fs as fs
import std.mem.heap as heap
import std.path as path_ops
import std.stdio as stdio
import std.str as str
import std.string as string
import std.vec as vec

const MAGIC_M: ubyte = 77
const MAGIC_T: ubyte = 84
const MAGIC_A: ubyte = 65
const MAGIC_P: ubyte = 80
const VERSION: uint = 1
const HEADER_FLAGS: uint = 0
const ENTRY_FLAGS_RAW: uint = 0
## The host's `AssetPack::HEADER_FORMAT` ("a4vvVQ<Q<"): magic, version u16,
## flags u16, entry count u32, index size u64, data offset u64.
const HEADER_SIZE_BYTES: ptr_uint = 28
const ENTRY_PREFIX_SIZE_BYTES: ptr_uint = 32

public enum Error: int
    open_failed = 1
    closed = 2
    invalid_magic = 3
    unsupported_version = 4
    unsupported_flags = 5
    range = 6
    malformed_header = 7
    malformed_index = 8
    entry_not_found = 9
    io = 10

public struct Reader:
    file: stdio.File?
    entry_count: uint
    ## Set by `close`; the closed file handle itself stays in `file` (a
    ## nullable opaque field cannot be reset to none by the C backend).
    closed: bool
    index_size: ptr_uint
    file_size: ptr_uint
    ## The index is loaded and validated once in `open`; lookups only scan this
    ## in-memory list, never the file.
    index: vec.Vec[IndexEntry]

struct IndexEntry:
    path: string.String
    entry_flags: uint
    data_offset: ptr_uint
    stored_size: ptr_uint
    unpacked_size: ptr_uint

struct EntryMetadata:
    path_length: ptr_uint
    entry_flags: uint
    data_offset: ptr_uint
    stored_size: ptr_uint
    unpacked_size: ptr_uint


public function open(path: str) -> Result[Reader, Error]:
    let file = stdio.file_open(path, "rb") else:
        return Result[Reader, Error].failure(error= Error.open_failed)

    var file_size: ptr_uint = 0
    match fs.metadata(path):
        Result.failure as metadata_failure:
            var metadata_error = metadata_failure.error
            metadata_error.release()
            stdio.file_close(file)
            return Result[Reader, Error].failure(error= Error.open_failed)
        Result.success as metadata_payload:
            file_size = metadata_payload.value.size

    if file_size < HEADER_SIZE_BYTES:
        stdio.file_close(file)
        return Result[Reader, Error].failure(error= Error.malformed_header)

    var header = zero[array[ubyte, 28]]
    let header_ptr = ptr_of(header[0])
    if not read_exact(file, header_ptr, HEADER_SIZE_BYTES):
        stdio.file_close(file)
        return Result[Reader, Error].failure(error= Error.malformed_header)

    if not valid_magic(header_ptr):
        stdio.file_close(file)
        return Result[Reader, Error].failure(error= Error.invalid_magic)

    let version = decode_ushort_le(unsafe: header_ptr + 4)
    if version != VERSION:
        stdio.file_close(file)
        return Result[Reader, Error].failure(error= Error.unsupported_version)

    let header_bits = decode_ushort_le(unsafe: header_ptr + 6)
    if header_bits != HEADER_FLAGS:
        stdio.file_close(file)
        return Result[Reader, Error].failure(error= Error.unsupported_flags)

    let entry_count = decode_uint_le(unsafe: header_ptr + 8)
    let index_size_result = decode_ulong_le(unsafe: header_ptr + 12)
    var index_size: ptr_uint
    match index_size_result:
        Result.failure as payload:
            stdio.file_close(file)
            return Result[Reader, Error].failure(error= payload.error)
        Result.success as index_payload:
            index_size = index_payload.value

    let data_offset_result = decode_ulong_le(unsafe: header_ptr + 20)
    var data_offset: ptr_uint
    match data_offset_result:
        Result.failure as payload:
            stdio.file_close(file)
            return Result[Reader, Error].failure(error= payload.error)
        Result.success as data_payload:
            data_offset = data_payload.value

    if index_size > file_size - HEADER_SIZE_BYTES:
        stdio.file_close(file)
        return Result[Reader, Error].failure(error= Error.malformed_header)

    if data_offset != HEADER_SIZE_BYTES + index_size:
        stdio.file_close(file)
        return Result[Reader, Error].failure(error= Error.malformed_header)

    # Every entry has a 32-byte prefix and at least a one-byte path.
    if ptr_uint<-entry_count > index_size / (ENTRY_PREFIX_SIZE_BYTES + 1):
        stdio.file_close(file)
        return Result[Reader, Error].failure(error= Error.malformed_header)

    match load_index(file, entry_count, index_size, data_offset, file_size):
        Result.failure as index_failure:
            stdio.file_close(file)
            return Result[Reader, Error].failure(error= index_failure.error)
        Result.success as index_payload:
            return Result[Reader, Error].success(value= Reader(
                file = file,
                entry_count = entry_count,
                closed = false,
                index_size = index_size,
                file_size = file_size,
                index = index_payload.value
            ))


extending Reader:
    public editable function close() -> void:
        if this.closed:
            return
        release_index_entries(ref_of(this.index))
        let file = this.file else:
            this.closed = true
            this.entry_count = 0
            return
        stdio.file_close(file)
        this.closed = true
        this.entry_count = 0


    public function read_bytes(logical_path: str) -> Result[bytes.Bytes, Error]:
        if this.closed or this.file == null:
            return Result[bytes.Bytes, Error].failure(error= Error.closed)

        var entry_index: ptr_uint = 0
        while entry_index < this.index.len():
            let entry_ptr = this.index.get(entry_index) else:
                break
            let entry = unsafe: read(entry_ptr)
            if entry.path.as_str().equal(logical_path):
                if stdio.file_seek(this.file, ptr_int<-entry.data_offset, stdio.SEEK_SET) != 0:
                    return Result[bytes.Bytes, Error].failure(error= Error.io)
                return read_payload(this.file, entry.stored_size)
            entry_index += 1

        return Result[bytes.Bytes, Error].failure(error= Error.entry_not_found)


function valid_magic(header: ptr[ubyte]) -> bool:
    unsafe:
        return (
            read(header + 0) == MAGIC_M and
            read(header + 1) == MAGIC_T and
            read(header + 2) == MAGIC_A and
            read(header + 3) == MAGIC_P
        )


function read_entry_metadata(file: stdio.File?) -> Result[EntryMetadata, Error]:
    var prefix = zero[array[ubyte, 32]]
    let prefix_ptr = ptr_of(prefix[0])
    if not read_exact(file, prefix_ptr, ENTRY_PREFIX_SIZE_BYTES):
        return Result[EntryMetadata, Error].failure(error= Error.malformed_index)

    let path_length = ptr_uint<-decode_uint_le(prefix_ptr)
    if path_length == 0:
        return Result[EntryMetadata, Error].failure(error= Error.malformed_index)

    let entry_bits = decode_uint_le(unsafe: prefix_ptr + 4)
    let data_offset_result = decode_ulong_le(unsafe: prefix_ptr + 8)
    var data_offset: ptr_uint
    match data_offset_result:
        Result.failure as payload:
            return Result[EntryMetadata, Error].failure(error= payload.error)
        Result.success as data_offset_payload:
            data_offset = data_offset_payload.value

    let stored_size_result = decode_ulong_le(unsafe: prefix_ptr + 16)
    var stored_size: ptr_uint
    match stored_size_result:
        Result.failure as payload:
            return Result[EntryMetadata, Error].failure(error= payload.error)
        Result.success as stored_size_payload:
            stored_size = stored_size_payload.value

    let unpacked_size_result = decode_ulong_le(unsafe: prefix_ptr + 24)
    var unpacked_size: ptr_uint
    match unpacked_size_result:
        Result.failure as payload:
            return Result[EntryMetadata, Error].failure(error= payload.error)
        Result.success as unpacked_size_payload:
            unpacked_size = unpacked_size_payload.value

    return Result[EntryMetadata, Error].success(value= EntryMetadata(
        path_length = path_length,
        entry_flags = entry_bits,
        data_offset = data_offset,
        stored_size = stored_size,
        unpacked_size = unpacked_size
    ))


## Read and validate the whole entry index once.  Every path is copied into an
## owned `String`, every data range is checked against the file size, and the
## index byte count must be exactly consumed.  A malformed pack fails here, not
## on the first lookup.
function load_index(
    file: stdio.File?,
    entry_count: uint,
    index_size: ptr_uint,
    data_base: ptr_uint,
    file_size: ptr_uint
) -> Result[vec.Vec[IndexEntry], Error]:
    var entries = vec.Vec[IndexEntry].create()
    if stdio.file_seek(file, HEADER_SIZE_BYTES, stdio.SEEK_SET) != 0:
        return Result[vec.Vec[IndexEntry], Error].failure(error= Error.io)

    var consumed: ptr_uint = 0
    var entry_index: uint = 0
    while entry_index < entry_count:
        if consumed > index_size or ENTRY_PREFIX_SIZE_BYTES > index_size - consumed:
            release_index_entries(ref_of(entries))
            return Result[vec.Vec[IndexEntry], Error].failure(error= Error.malformed_index)

        let metadata_result = read_entry_metadata(file)
        match metadata_result:
            Result.failure as payload:
                release_index_entries(ref_of(entries))
                return Result[vec.Vec[IndexEntry], Error].failure(error= payload.error)
            Result.success as metadata_payload:
                let metadata = metadata_payload.value
                if metadata.path_length > index_size - consumed - ENTRY_PREFIX_SIZE_BYTES:
                    release_index_entries(ref_of(entries))
                    return Result[vec.Vec[IndexEntry], Error].failure(error= Error.malformed_index)

                if metadata.entry_flags != ENTRY_FLAGS_RAW:
                    release_index_entries(ref_of(entries))
                    return Result[vec.Vec[IndexEntry], Error].failure(error= Error.unsupported_flags)

                if metadata.stored_size != metadata.unpacked_size:
                    release_index_entries(ref_of(entries))
                    return Result[vec.Vec[IndexEntry], Error].failure(error= Error.malformed_index)

                if metadata.data_offset < data_base or metadata.data_offset > file_size:
                    release_index_entries(ref_of(entries))
                    return Result[vec.Vec[IndexEntry], Error].failure(error= Error.range)

                if metadata.stored_size > file_size - metadata.data_offset:
                    release_index_entries(ref_of(entries))
                    return Result[vec.Vec[IndexEntry], Error].failure(error= Error.range)

                let path_buffer = heap.must_alloc[ubyte](metadata.path_length)
                if not read_exact(file, path_buffer, metadata.path_length):
                    heap.release(path_buffer)
                    release_index_entries(ref_of(entries))
                    return Result[vec.Vec[IndexEntry], Error].failure(error= Error.malformed_index)

                let path_view = span[ubyte](data = path_buffer, len = metadata.path_length)
                let path_text_opt = str.utf8_byte_span_as_str(path_view)
                let path_text = path_text_opt else:
                    heap.release(path_buffer)
                    release_index_entries(ref_of(entries))
                    return Result[vec.Vec[IndexEntry], Error].failure(error= Error.malformed_index)

                var path_copy = string.String.from_str(path_text)
                heap.release(path_buffer)
                entries.push(IndexEntry(
                    path = path_copy,
                    entry_flags = metadata.entry_flags,
                    data_offset = metadata.data_offset,
                    stored_size = metadata.stored_size,
                    unpacked_size = metadata.unpacked_size
                ))
                consumed += ENTRY_PREFIX_SIZE_BYTES + metadata.path_length
        entry_index += 1

    if consumed != index_size:
        release_index_entries(ref_of(entries))
        return Result[vec.Vec[IndexEntry], Error].failure(error= Error.malformed_index)

    return Result[vec.Vec[IndexEntry], Error].success(value= entries)


function release_index_entries(entries: ref[vec.Vec[IndexEntry]]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        let entry_ptr = entries.get(i) else:
            break
        unsafe:
            read(entry_ptr).path.release()
        i += 1
    entries.release()


function read_payload(file: stdio.File?, size_bytes: ptr_uint) -> Result[bytes.Bytes, Error]:
    if size_bytes == 0:
        return Result[bytes.Bytes, Error].success(value= bytes.Bytes.empty())

    let data = heap.must_alloc[ubyte](size_bytes)
    if not read_exact(file, data, size_bytes):
        heap.release(data)
        return Result[bytes.Bytes, Error].failure(error= Error.io)

    return Result[bytes.Bytes, Error].success(value= bytes.Bytes(data = data, len = size_bytes))


function read_exact(file: stdio.File?, buffer: ptr[ubyte], size_bytes: ptr_uint) -> bool:
    if size_bytes == 0:
        return true

    return stdio.file_read_bytes(unsafe: ptr[void]<-buffer, 1, size_bytes, file) == size_bytes


function decode_ushort_le(bytes: ptr[ubyte]) -> uint:
    unsafe:
        return uint<-read(bytes + 0) | (uint<-read(bytes + 1) << 8)


function decode_uint_le(bytes: ptr[ubyte]) -> uint:
    unsafe:
        return (
            uint<-read(bytes + 0) |
            uint<-read(bytes + 1) << 8 |
            uint<-read(bytes + 2) << 16 |
            uint<-read(bytes + 3) << 24
        )


function decode_ulong_le(bytes: ptr[ubyte]) -> Result[ptr_uint, Error]:
    if size_of(ptr[void]) < 8:
        var upper_index: ptr_uint = 4
        while upper_index < 8:
            unsafe:
                if read(bytes + upper_index) != 0:
                    return Result[ptr_uint, Error].failure(error= Error.range)
            upper_index += 1

    let word_bytes = size_of(ptr[void])
    var count = word_bytes
    if count > 8:
        count = 8

    var value: ptr_uint = 0
    var index: ptr_uint = 0
    while index < count:
        unsafe:
            value = value | (ptr_uint<-read(bytes + index) << (index * 8))
        index += 1

    return Result[ptr_uint, Error].success(value= value)


# =============================================================================
#  Writer — the host's `AssetPack.write` (lib/milk_tea/tooling/asset_pack.rb)
# =============================================================================

## One source file staged into the pack, with its logical path.
struct PackSourceEntry:
    source_path: string.String
    logical_path: string.String
    stored_size: ptr_uint


function pack_entry_compare(left: ptr[PackSourceEntry], right: ptr[PackSourceEntry]) -> int:
    return unsafe: read(left).logical_path.as_str().compare(unsafe: read(right).logical_path.as_str())


## Write an MTAP pack at `output_path` containing the given files/directories
## (absolute paths).  Entries use the source basename as their logical root and
## are sorted by logical path; the format is byte-compatible with the host's
## AssetPack writer.
public function write(output_path: str, source_paths: span[string.String]) -> Result[bool, string.String]:
    var i: ptr_uint = 0
    while i < source_paths.len:
        let source_ptr = unsafe: read(source_paths.data + i).as_str()
        if fs.is_directory(source_ptr):
            if path_within(output_path, source_ptr):
                var message = string.String.from_str("asset pack output would be written inside source tree: ")
                message.append(output_path)
                return Result[bool, string.String].failure(error = message)
        else if output_path.equal(source_ptr):
            var message = string.String.from_str("asset pack output would overwrite source file: ")
            message.append(output_path)
            return Result[bool, string.String].failure(error = message)
        i += 1

    var entries = vec.Vec[PackSourceEntry].create()
    defer: release_pack_entries(ref_of(entries))
    i = 0
    while i < source_paths.len:
        let source = unsafe: read(source_paths.data + i).as_str()
        let logical = path_ops.basename(source)
        if not collect_pack_entries(source, logical, ref_of(entries)):
            return Result[bool, string.String].failure(
                error = string.String.from_str("asset pack source not found: ")
            )
        i += 1
    entries.sort_by(pack_entry_compare)

    var index_size: ptr_uint = 0
    var ei: ptr_uint = 0
    while ei < entries.len():
        let entry_ptr = entries.get(ei) else:
            break
        index_size += ENTRY_PREFIX_SIZE_BYTES + unsafe: read(entry_ptr).logical_path.len()
        ei += 1
    let data_offset = HEADER_SIZE_BYTES + index_size

    let parent = path_ops.dirname(output_path)
    match fs.create_directories(parent):
        Result.failure as dir_failure:
            var dir_error = dir_failure.error
            let message = string.String.from_str(dir_error.message.as_str())
            dir_error.release()
            return Result[bool, string.String].failure(error = message)
        Result.success:
            pass

    var temp_owner: string.String
    match fs.create_temporary_file(parent, "milk-tea-asset-pack", ".bin"):
        Result.failure as temp_failure:
            var temp_error = temp_failure.error
            let message = string.String.from_str(temp_error.message.as_str())
            temp_error.release()
            return Result[bool, string.String].failure(error = message)
        Result.success as temp_payload:
            temp_owner = temp_payload.value
    defer: temp_owner.release()

    let file = stdio.file_open(temp_owner.as_str(), "wb") else:
        return Result[bool, string.String].failure(error = string.String.from_str("asset pack open failed"))

    var header = vec.Vec[ubyte].create()
    defer: header.release()
    header.push(77)
    header.push(84)
    header.push(65)
    header.push(80)
    push_u16_le(ref_of(header), 1)
    push_u16_le(ref_of(header), HEADER_FLAGS)
    push_u32_le(ref_of(header), uint<-entries.len())
    push_u64_le(ref_of(header), ptr_uint<-index_size)
    push_u64_le(ref_of(header), ptr_uint<-data_offset)

    var next_offset = data_offset
    ei = 0
    while ei < entries.len():
        let entry_ptr = entries.get(ei) else:
            break
        let entry = unsafe: read(entry_ptr)
        push_u32_le(ref_of(header), uint<-entry.logical_path.len())
        push_u32_le(ref_of(header), ENTRY_FLAGS_RAW)
        push_u64_le(ref_of(header), ptr_uint<-next_offset)
        push_u64_le(ref_of(header), ptr_uint<-entry.stored_size)
        push_u64_le(ref_of(header), ptr_uint<-entry.stored_size)
        let logical = entry.logical_path.as_str()
        header.append_span(unsafe: span[ubyte](data = ptr[ubyte]<-logical.data, len = logical.len))
        next_offset += entry.stored_size
        ei += 1

    let header_span = header.as_span()
    if header_span.len > 0:
        if stdio.file_write_bytes(unsafe: ptr[void]<-header_span.data, 1, header_span.len, file) != header_span.len:
            stdio.file_close(file)
            return Result[bool, string.String].failure(error = string.String.from_str("asset pack write failed"))

    ei = 0
    while ei < entries.len():
        let entry_ptr = entries.get(ei) else:
            break
        let entry = unsafe: read(entry_ptr)
        let source_file = stdio.file_open(entry.source_path.as_str(), "rb") else:
            stdio.file_close(file)
            return Result[bool, string.String].failure(error = string.String.from_str("asset pack source not found: "))
        var buffer = zero[array[ubyte, 8192]]
        let buffer_ptr = ptr_of(buffer[0])
        var copy_ok = true
        while true:
            let read_count = stdio.file_read_bytes(unsafe: ptr[void]<-buffer_ptr, 1, 8192, source_file)
            if read_count == 0:
                break
            if stdio.file_write_bytes(unsafe: ptr[void]<-buffer_ptr, 1, read_count, file) != read_count:
                copy_ok = false
                break
        stdio.file_close(source_file)
        if not copy_ok:
            stdio.file_close(file)
            return Result[bool, string.String].failure(error = string.String.from_str("asset pack write failed"))
        ei += 1

    stdio.file_flush(file)
    stdio.file_close(file)

    if fs.exists(output_path):
        match fs.remove(output_path):
            Result.failure:
                return Result[bool, string.String].failure(error = string.String.from_str("asset pack output could not be replaced"))
            Result.success:
                pass
    match fs.rename(temp_owner.as_str(), output_path):
        Result.failure as rename_failure:
            var rename_error = rename_failure.error
            let message = string.String.from_str(rename_error.message.as_str())
            rename_error.release()
            return Result[bool, string.String].failure(error = message)
        Result.success:
            pass
    return Result[bool, string.String].success(value = true)


function collect_pack_entries(source_path: str, logical_path: str, entries: ref[vec.Vec[PackSourceEntry]]) -> bool:
    match fs.metadata(source_path):
        Result.failure:
            return false
        Result.success as meta_payload:
            let metadata = meta_payload.value
            if metadata.is_directory():
                var names = vec.Vec[string.String].create()
                defer: release_pack_names(ref_of(names))
                match fs.list_entries(source_path):
                    Result.failure:
                        return false
                    Result.success as entries_payload:
                        var listed = entries_payload.value
                        defer: listed.release()
                        var list_index: ptr_uint = 0
                        while list_index < listed.len():
                            let name = listed.get(list_index) else:
                                break
                            names.push(string.String.from_str(name))
                            list_index += 1
                var views = vec.Vec[str].create()
                defer: views.release()
                var i: ptr_uint = 0
                while i < names.len():
                    let name_ptr = names.get(i) else:
                        break
                    views.push(unsafe: read(name_ptr).as_str())
                    i += 1
                views.sort_by(str_view_compare)
                i = 0
                while i < views.len():
                    let child_ptr = views.get(i) else:
                        break
                    let child = unsafe: read(child_ptr)
                    var child_source = path_ops.join(source_path, child)
                    var child_logical = string.String.from_str(logical_path)
                    child_logical.push_byte('/')
                    child_logical.append(child)
                    let ok = collect_pack_entries(child_source.as_str(), child_logical.as_str(), entries)
                    child_source.release()
                    child_logical.release()
                    if not ok:
                        return false
                    i += 1
                return true
            if metadata.is_file():
                entries.push(PackSourceEntry(
                    source_path = string.String.from_str(source_path),
                    logical_path = string.String.from_str(logical_path),
                    stored_size = metadata.size,
                ))
                return true
            return false


function str_view_compare(left: ptr[str], right: ptr[str]) -> int:
    return unsafe: read(left).compare(unsafe: read(right))


function release_pack_names(names: ref[vec.Vec[string.String]]) -> void:
    var i: ptr_uint = 0
    while i < names.len():
        let name = names.get(i) else:
            break
        unsafe:
            read(name).release()
        i += 1
    names.release()


function release_pack_entries(entries: ref[vec.Vec[PackSourceEntry]]) -> void:
    var i: ptr_uint = 0
    while i < entries.len():
        let entry = entries.get(i) else:
            break
        unsafe:
            var value = read(entry)
            value.source_path.release()
            value.logical_path.release()
        i += 1
    entries.release()


function path_within(path: str, root: str) -> bool:
    if path.equal(root):
        return true
    if path.len <= root.len:
        return false
    if not path.slice(0, root.len).equal(root):
        return false
    return path.byte_at(root.len) == '/'


function push_u16_le(target: ref[vec.Vec[ubyte]], value: uint) -> void:
    target.push(ubyte<-(value & 255))
    target.push(ubyte<-((value >> 8) & 255))


function push_u32_le(target: ref[vec.Vec[ubyte]], value: uint) -> void:
    var index: ptr_uint = 0
    while index < 4:
        target.push(ubyte<-((value >> (index * 8)) & 255))
        index += 1


function push_u64_le(target: ref[vec.Vec[ubyte]], value: ptr_uint) -> void:
    var index: ptr_uint = 0
    while index < 8:
        target.push(ubyte<-((value >> (index * 8)) & 255))
        index += 1
