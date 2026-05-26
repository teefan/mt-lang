import std.bytes as bytes
import std.c.zlib as c
import std.string as string


public const DEFAULT_COMPRESSION: int = c.MT_ZLIB_DEFAULT_COMPRESSION
public const BEST_SPEED: int = c.MT_ZLIB_BEST_SPEED
public const BEST_COMPRESSION: int = c.MT_ZLIB_BEST_COMPRESSION


public struct Error:
    code: int
    message: string.String


function take_owned_string(data: ptr[char]?, len: ptr_uint) -> string.String:
    if data == null:
        if len != 0:
            fatal(c"gzip.take_owned_string missing storage")

        return string.String.create()

    return unsafe: string.String(data = ptr[ubyte]<-data, len = len, capacity = len, owns_storage = true)


function take_owned_bytes(data: ptr[ubyte]?, len: ptr_uint) -> bytes.Bytes:
    if data == null:
        if len != 0:
            fatal(c"gzip.take_owned_bytes missing storage")

        return bytes.Bytes.empty()

    return bytes.Bytes(data = data, len = len)


function take_error(raw: c.mt_zlib_error, fallback: str) -> Error:
    if raw.message_data == null and raw.message_len == 0:
        return Error(code = raw.code, message = string.String.from_str(fallback))

    return Error(code = raw.code, message = take_owned_string(raw.message_data, raw.message_len))


function static_error(message: str) -> Error:
    return Error(code = -1, message = string.String.from_str(message))


extending Error:
    public mutable function release() -> void:
        this.message.release()
        return


public function compress_bytes(data: span[ubyte]) -> Result[bytes.Bytes, Error]:
    return compress_bytes_with_level(data, DEFAULT_COMPRESSION)


public function compress_bytes_with_level(data: span[ubyte], level: int) -> Result[bytes.Bytes, Error]:
    if level < DEFAULT_COMPRESSION or level > BEST_COMPRESSION:
        return Result[bytes.Bytes, Error].failure(error= static_error("gzip compression level must be between -1 and 9"))

    var raw_bytes = zero[c.mt_zlib_bytes]
    var raw_error = zero[c.mt_zlib_error]
    let status_code = c.mt_gzip_compress(data.data, data.len, level, raw_bytes, raw_error)
    if status_code != 0:
        return Result[bytes.Bytes, Error].failure(error= take_error(raw_error, "gzip compress failed"))

    return Result[bytes.Bytes, Error].success(value= take_owned_bytes(raw_bytes.data, raw_bytes.len))


public function decompress_bytes(data: span[ubyte]) -> Result[bytes.Bytes, Error]:
    var raw_bytes = zero[c.mt_zlib_bytes]
    var raw_error = zero[c.mt_zlib_error]
    let status_code = c.mt_gzip_decompress(data.data, data.len, raw_bytes, raw_error)
    if status_code != 0:
        return Result[bytes.Bytes, Error].failure(error= take_error(raw_error, "gzip decompress failed"))

    return Result[bytes.Bytes, Error].success(value= take_owned_bytes(raw_bytes.data, raw_bytes.len))
