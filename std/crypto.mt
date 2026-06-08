import std.bytes as bytes
import std.c.crypto as raw
import std.mem.heap as heap
import std.string as string

public struct Error:
    message: string.String


function status_error(message: str) -> Error:
    return Error(message = string.String.from_str(message))


public function sha256(data: span[ubyte]) -> bytes.Bytes:
    let digest = heap.must_alloc[ubyte](raw.SHA256_DIGEST_LENGTH)
    let ok = raw.mt_sha256(data.data, data.len, digest)
    if ok == 0:
        heap.release(digest)
        return bytes.Bytes.empty()

    return bytes.Bytes(data = digest, len = raw.SHA256_DIGEST_LENGTH)


public function sha256_to_str(data: span[ubyte]) -> string.String:
    var digest = sha256(data)
    defer digest.release()

    var result = string.String.with_capacity(raw.SHA256_DIGEST_LENGTH * 2)
    var index: ptr_uint = 0
    let digest_span = digest.as_span()
    while index < raw.SHA256_DIGEST_LENGTH:
        let value = unsafe: read(digest_span.data + index)
        let high = value >> 4
        let low = value & 0x0F
        result.push_byte(hex_digit(high))
        result.push_byte(hex_digit(low))
        index += 1

    return result


public function hmac_sha256(key: span[ubyte], data: span[ubyte]) -> bytes.Bytes:
    let digest = heap.must_alloc[ubyte](raw.SHA256_DIGEST_LENGTH)
    let ok = raw.mt_hmac_sha256(key.data, key.len, data.data, data.len, digest)
    if ok == 0:
        heap.release(digest)
        return bytes.Bytes.empty()

    return bytes.Bytes(data = digest, len = raw.SHA256_DIGEST_LENGTH)


public function random_bytes(count: ptr_uint) -> Result[bytes.Bytes, Error]:
    if count == 0:
        return Result[bytes.Bytes, Error].failure(error = status_error("random_bytes: count must be greater than zero"))

    let buffer = heap.must_alloc[ubyte](count)
    let ok = raw.mt_random_bytes(buffer, count)
    if ok == 0:
        heap.release(buffer)
        return Result[bytes.Bytes, Error].failure(error = status_error("random_bytes: failed to generate random data"))

    return Result[bytes.Bytes, Error].success(value = bytes.Bytes(data = buffer, len = count))


function hex_digit(value: ubyte) -> ubyte:
    if value < 10:
        return 48 + value

    return 97 + (value - 10)


extending Error:
    public editable function release() -> void:
        this.message.release()
