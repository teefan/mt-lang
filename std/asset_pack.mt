import std.bytes as bytes
import std.mem.heap as heap
import std.stdio as stdio


const MAGIC_M: ubyte = 77
const MAGIC_T: ubyte = 84
const MAGIC_A: ubyte = 65
const MAGIC_P: ubyte = 80
const VERSION: uint = 1
const HEADER_FLAGS: uint = 0
const ENTRY_FLAGS_RAW: uint = 0
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


struct EntryMetadata:
    path_length: ptr_uint
    entry_flags: uint
    data_offset: ptr_uint
    stored_size: ptr_uint
    unpacked_size: ptr_uint


public function open(path: str) -> Result[Reader, Error]:
    let file = stdio.open(path, "rb") else:
        return Result[Reader, Error].failure(error= Error.open_failed)

    var header = zero[array[ubyte, 28]]
    let header_ptr = ptr_of(header[0])
    if not read_exact(file, header_ptr, HEADER_SIZE_BYTES):
        stdio.close(file)
        return Result[Reader, Error].failure(error= Error.malformed_header)

    if not valid_magic(header_ptr):
        stdio.close(file)
        return Result[Reader, Error].failure(error= Error.invalid_magic)

    let version = decode_u16_le(unsafe: header_ptr + 4)
    if version != VERSION:
        stdio.close(file)
        return Result[Reader, Error].failure(error= Error.unsupported_version)

    let header_bits = decode_u16_le(unsafe: header_ptr + 6)
    if header_bits != HEADER_FLAGS:
        stdio.close(file)
        return Result[Reader, Error].failure(error= Error.unsupported_flags)

    let entry_count = decode_u32_le(unsafe: header_ptr + 8)
    let index_size_result = decode_u64_le(unsafe: header_ptr + 12)
    var index_size: ptr_uint
    match index_size_result:
        Result.failure as payload:
            stdio.close(file)
            return Result[Reader, Error].failure(error= payload.error)
        Result.success as index_payload:
            index_size = index_payload.value

    let data_offset_result = decode_u64_le(unsafe: header_ptr + 20)
    var data_offset: ptr_uint
    match data_offset_result:
        Result.failure as payload:
            stdio.close(file)
            return Result[Reader, Error].failure(error= payload.error)
        Result.success as data_payload:
            data_offset = data_payload.value

    if data_offset != HEADER_SIZE_BYTES + index_size:
        stdio.close(file)
        return Result[Reader, Error].failure(error= Error.malformed_header)

    return Result[Reader, Error].success(value= Reader(file = file, entry_count = entry_count))


extending Reader:
    public mutable function close() -> void:
        if this.file != null:
            stdio.close(this.file)

        this.file = null
        this.entry_count = 0


    public function read_bytes(logical_path: str) -> Result[bytes.Bytes, Error]:
        if this.file == null:
            return Result[bytes.Bytes, Error].failure(error= Error.closed)

        if stdio.seek(this.file, HEADER_SIZE_BYTES, stdio.SEEK_SET) != 0:
            return Result[bytes.Bytes, Error].failure(error= Error.io)

        var entry_index: uint = 0
        while entry_index < this.entry_count:
            let metadata_result = read_entry_metadata(this.file)
            match metadata_result:
                Result.failure as payload:
                    return Result[bytes.Bytes, Error].failure(error= payload.error)
                Result.success as metadata_payload:
                    let metadata = metadata_payload.value
                    let path_match_result = read_path_matches(this.file, metadata.path_length, logical_path)
                    match path_match_result:
                        Result.failure as payload:
                            return Result[bytes.Bytes, Error].failure(error= payload.error)
                        Result.success as match_payload:
                            if match_payload.value:
                                if metadata.entry_flags != ENTRY_FLAGS_RAW:
                                    return Result[bytes.Bytes, Error].failure(error= Error.unsupported_flags)

                                if metadata.stored_size != metadata.unpacked_size:
                                    return Result[bytes.Bytes, Error].failure(error= Error.malformed_index)

                                if stdio.seek(this.file, ptr_int<-metadata.data_offset, stdio.SEEK_SET) != 0:
                                    return Result[bytes.Bytes, Error].failure(error= Error.io)

                                return read_payload(this.file, metadata.stored_size)
                    entry_index += 1

        return Result[bytes.Bytes, Error].failure(error= Error.entry_not_found)


function valid_magic(header: ptr[ubyte]) -> bool:
    unsafe:
        return read(header + 0) == MAGIC_M and read(header + 1) == MAGIC_T and read(header + 2) == MAGIC_A and read(header + 3) == MAGIC_P


function read_entry_metadata(file: stdio.File?) -> Result[EntryMetadata, Error]:
    var prefix = zero[array[ubyte, 32]]
    let prefix_ptr = ptr_of(prefix[0])
    if not read_exact(file, prefix_ptr, ENTRY_PREFIX_SIZE_BYTES):
        return Result[EntryMetadata, Error].failure(error= Error.malformed_index)

    let path_length = ptr_uint<-decode_u32_le(prefix_ptr)
    if path_length == 0:
        return Result[EntryMetadata, Error].failure(error= Error.malformed_index)

    let entry_bits = decode_u32_le(unsafe: prefix_ptr + 4)
    let data_offset_result = decode_u64_le(unsafe: prefix_ptr + 8)
    var data_offset: ptr_uint
    match data_offset_result:
        Result.failure as payload:
            return Result[EntryMetadata, Error].failure(error= payload.error)
        Result.success as data_offset_payload:
            data_offset = data_offset_payload.value

    let stored_size_result = decode_u64_le(unsafe: prefix_ptr + 16)
    var stored_size: ptr_uint
    match stored_size_result:
        Result.failure as payload:
            return Result[EntryMetadata, Error].failure(error= payload.error)
        Result.success as stored_size_payload:
            stored_size = stored_size_payload.value

    let unpacked_size_result = decode_u64_le(unsafe: prefix_ptr + 24)
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


function read_path_matches(file: stdio.File?, path_length: ptr_uint, logical_path: str) -> Result[bool, Error]:
    let path_buffer = heap.must_alloc[ubyte](path_length)
    defer heap.release(path_buffer)

    if not read_exact(file, ptr[ubyte]<-path_buffer, path_length):
        return Result[bool, Error].failure(error= Error.malformed_index)

    return Result[bool, Error].success(value= bytes_equal_str(ptr[ubyte]<-path_buffer, path_length, logical_path))


function read_payload(file: stdio.File?, size_bytes: ptr_uint) -> Result[bytes.Bytes, Error]:
    if size_bytes == 0:
        return Result[bytes.Bytes, Error].success(value= bytes.Bytes.empty())

    let data = heap.must_alloc[ubyte](size_bytes)
    if not read_exact(file, ptr[ubyte]<-data, size_bytes):
        heap.release(data)
        return Result[bytes.Bytes, Error].failure(error= Error.io)

    return Result[bytes.Bytes, Error].success(value= bytes.Bytes(data = ptr[ubyte]<-data, len = size_bytes))


function read_exact(file: stdio.File?, buffer: ptr[ubyte], size_bytes: ptr_uint) -> bool:
    if size_bytes == 0:
        return true

    return stdio.read_bytes(unsafe: ptr[void]<-buffer, 1, size_bytes, file) == size_bytes


function bytes_equal_str(left: ptr[ubyte], left_len: ptr_uint, right: str) -> bool:
    if left_len != right.len:
        return false

    var index: ptr_uint = 0
    while index < left_len:
        unsafe:
            if read(left + index) != ubyte<-read(right.data + index):
                return false
        index += 1

    return true


function decode_u16_le(bytes: ptr[ubyte]) -> uint:
    unsafe:
        return uint<-read(bytes + 0) | (uint<-read(bytes + 1) << 8)


function decode_u32_le(bytes: ptr[ubyte]) -> uint:
    unsafe:
        return uint<-read(bytes + 0) |
            (uint<-read(bytes + 1) << 8) |
            (uint<-read(bytes + 2) << 16) |
            (uint<-read(bytes + 3) << 24)


function decode_u64_le(bytes: ptr[ubyte]) -> Result[ptr_uint, Error]:
    if ptr_uint<-size_of(ptr[void]) < 8:
        unsafe:
            var upper_index: ptr_uint = 4
            while upper_index < 8:
                if read(bytes + upper_index) != 0:
                    return Result[ptr_uint, Error].failure(error= Error.range)
                upper_index += 1

    let word_bytes = ptr_uint<-size_of(ptr[void])
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
