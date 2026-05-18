import std.bytes as bytes
import std.c.tls as c
import std.mem.arena as arena
import std.string as string


public struct Error:
    code: int
    message: string.String


function take_owned_string(data: ptr[char]?, len: ptr_uint) -> string.String:
    if data == null:
        if len != 0:
            fatal(c"tls.take_owned_string missing storage")

        return string.String.create()

    return unsafe: string.String(data = ptr[ubyte]<-data, len = len, capacity = len)


function take_owned_bytes(data: ptr[ubyte]?, len: ptr_uint) -> bytes.Bytes:
    if data == null:
        if len != 0:
            fatal(c"tls.take_owned_bytes missing storage")

        return bytes.Bytes.empty()

    return bytes.Bytes(data = data, len = len)


function take_error(raw: c.mt_tls_error, fallback: str) -> Error:
    if raw.message_data == null and raw.message_len == 0:
        return Error(code = raw.code, message = string.String.from_str(fallback))

    return Error(code = raw.code, message = take_owned_string(raw.message_data, raw.message_len))


extending Error:
    public mutable function release() -> void:
        this.message.release()
        return


public function exchange(host: str, port: int, request: span[ubyte]) -> Result[bytes.Bytes, Error]:
    var host_storage = arena.create(host.len + 1)
    defer host_storage.release()

    var raw_response = zero[c.mt_tls_bytes]
    var raw_error = zero[c.mt_tls_error]
    let status_code = c.mt_tls_exchange(host_storage.to_cstr(host), port, request.data, request.len, raw_response, raw_error)
    if status_code != 0:
        return Result[bytes.Bytes, Error].failure(error = take_error(raw_error, "tls exchange failed"))

    return Result[bytes.Bytes, Error].success(value = take_owned_bytes(raw_response.data, raw_response.len))
