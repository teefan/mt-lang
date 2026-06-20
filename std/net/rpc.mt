import std.async as aio
import std.binary as bin
import std.bytes as bytes
import std.net.mux as mux
import std.string as string

const header_bytes: ptr_uint = 4

const err_send_failed: int = -1
const err_timeout: int = -2
const err_unexpected: int = -3

public struct Error:
    code: int
    message: string.String


extending Error:
    public editable function release() -> void:
        this.message.release()


function rpc_error(code: int, msg: str) -> Error:
    return Error(code = code, message = string.String.from_str(msg))


public function build_call(request_id: uint, payload: span[ubyte]) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(header_bytes + payload.len)
    w.write_uint(request_id)
    var i: ptr_uint = 0
    while i < payload.len:
        w.write_ubyte(payload[i])
        i += 1
    return w.finish()


public function build_reply(request_id: uint, payload: span[ubyte]) -> bytes.Bytes:
    return build_call(request_id, payload)


public function parse_request_id(data: span[ubyte]) -> Result[uint, Error]:
    if data.len < header_bytes:
        return Result[uint, Error].failure(error = rpc_error(err_unexpected, "rpc frame too small"))
    var r = bin.reader(data)
    return r.read_uint().map_err(proc(_: bin.Error) -> Error: rpc_error(err_unexpected, "malformed rpc frame"))


public function payload_after_header(data: span[ubyte]) -> span[ubyte]:
    if data.len <= header_bytes:
        let empty = bytes.Bytes.empty()
        let result = empty.as_span()
        return result
    unsafe:
        return span[ubyte](data = ptr[ubyte]<-data.data + header_bytes, len = data.len - header_bytes)


public async function call_and_wait(
    conn: ref[mux.MuxedConnection],
    channel_id: ubyte,
    call_type_id: ushort,
    response_type_id: ushort,
    request_id: uint,
    payload: span[ubyte]
) -> Result[bytes.Bytes, Error]:
    var call_packet = build_call(request_id, payload)
    defer call_packet.release()

    let send_result = await conn.mux_send(channel_id, call_type_id, call_packet.as_span(), mux.flag_reliable)
    match send_result:
        Result.failure:
            return Result[bytes.Bytes, Error].failure(error = rpc_error(err_send_failed, "rpc send failed"))
        Result.success:
            pass

    var frame: uint = 0
    while frame < 120:
        let msg_opt = conn.try_recv()
        match msg_opt:
            Option.some as mp:
                var msg = mp.value
                defer msg.release()
                if msg.type_id == response_type_id and msg.channel_id == channel_id:
                    let id_result = parse_request_id(msg.payload.as_span())
                    match id_result:
                        Result.success as ip:
                            if ip.value == request_id:
                                let result_data = payload_after_header(msg.payload.as_span())
                                var copy = bin.Writer.with_capacity(result_data.len)
                                var i: ptr_uint = 0
                                while i < result_data.len:
                                    copy.write_ubyte(result_data[i])
                                    i += 1
                                return Result[bytes.Bytes, Error].success(value = copy.finish())
                        Result.failure:
                            pass
            Option.none:
                pass

        await aio.sleep(16)
        frame += 1

    return Result[bytes.Bytes, Error].failure(error = rpc_error(err_timeout, "rpc call timed out"))


public async function send_reply(
    conn: ref[mux.MuxedConnection],
    channel_id: ubyte,
    response_type_id: ushort,
    request_id: uint,
    payload: span[ubyte]
) -> Result[bool, Error]:
    var reply_packet = build_reply(request_id, payload)
    defer reply_packet.release()
    let send_result = await conn.mux_send(channel_id, response_type_id, reply_packet.as_span(), mux.flag_reliable)
    match send_result:
        Result.failure:
            return Result[bool, Error].failure(error = rpc_error(err_send_failed, "reply send failed"))
        Result.success:
            return Result[bool, Error].success(value = true)
