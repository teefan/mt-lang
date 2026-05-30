import std.async as aio
import std.bytes as bytes
import std.net as net
import std.string as string
import std.vec as vec


const frame_header_bytes: ptr_uint = 4
const discard_chunk_bytes: ptr_uint = 4096
const max_frame_payload_bytes: ptr_uint = 4294967295


public struct Error:
    code: int
    message: string.String


public struct Stream:
    stream: net.TcpStream
    max_packet_bytes: ptr_uint


public struct Listener:
    listener: net.TcpListener
    max_packet_bytes: ptr_uint


function packet_error(code: int, message: str) -> Error:
    return Error(code = code, message = string.String.from_str(message))


function error_from_net(source: net.Error) -> Error:
    return Error(code = source.code, message = source.message)


function encode_packet_length(length: ptr_uint) -> array[ubyte, 4]:
    let raw = uint<-length
    return array[ubyte, 4](
        ubyte<-((raw >> 24) & 255),
        ubyte<-((raw >> 16) & 255),
        ubyte<-((raw >> 8) & 255),
        ubyte<-(raw & 255)
    )


function decode_packet_length(header: bytes.Bytes) -> ptr_uint:
    if header.len != frame_header_bytes:
        fatal(c"packet frame header length mismatch")

    let header_span = header.as_span()
    let length = ((uint<-header_span[0]) << 24) |
        ((uint<-header_span[1]) << 16) |
        ((uint<-header_span[2]) << 8) |
        (uint<-header_span[3])
    return ptr_uint<-length


function frame_bytes(content: span[ubyte]) -> bytes.Bytes:
    var framed = vec.Vec[ubyte].with_capacity(frame_header_bytes + content.len)
    defer framed.release()

    let header = encode_packet_length(content.len)
    framed.append_array(header)
    framed.append_span(content)
    return bytes.Bytes.copy(framed.as_span())


async function discard_exactly(stream: net.TcpStream, byte_count: ptr_uint) -> Result[bool, Error]:
    var remaining = byte_count
    while remaining != 0:
        var chunk_bytes = discard_chunk_bytes
        if remaining < chunk_bytes:
            chunk_bytes = remaining

        let discard_result = await stream.read_exactly(chunk_bytes)
        match discard_result:
            Result.failure as payload:
                return Result[bool, Error].failure(error = error_from_net(payload.error))
            Result.success as payload:
                var chunk = payload.value
                chunk.release()
                remaining -= chunk_bytes

    return Result[bool, Error].success(value = true)


public async function connect_on(runtime: aio.Runtime, address: net.SocketAddress, max_packet_bytes: ptr_uint) -> Result[Stream, Error]:
    let connect_result = await net.connect_on(runtime, address)
    match connect_result:
        Result.failure as payload:
            return Result[Stream, Error].failure(error = error_from_net(payload.error))
        Result.success as payload:
            return Result[Stream, Error].success(value = wrap(payload.value, max_packet_bytes))


public async function connect(address: net.SocketAddress, max_packet_bytes: ptr_uint) -> Result[Stream, Error]:
    return await connect_on(aio.current_runtime(), address, max_packet_bytes)


public function listen_on(runtime: aio.Runtime, address: net.SocketAddress, backlog: int, max_packet_bytes: ptr_uint) -> Result[Listener, Error]:
    let listen_result = net.listen_on(runtime, address, backlog)
    match listen_result:
        Result.failure as payload:
            return Result[Listener, Error].failure(error = error_from_net(payload.error))
        Result.success as payload:
            return Result[Listener, Error].success(value = Listener(listener = payload.value, max_packet_bytes = max_packet_bytes))


public function listen(address: net.SocketAddress, backlog: int, max_packet_bytes: ptr_uint) -> Result[Listener, Error]:
    return listen_on(aio.current_runtime(), address, backlog, max_packet_bytes)


public function wrap(stream: net.TcpStream, max_packet_bytes: ptr_uint) -> Stream:
    return Stream(stream = stream, max_packet_bytes = max_packet_bytes)


extending Error:
    public mutable function release() -> void:
        this.message.release()


extending Stream:
    public mutable function release() -> void:
        this.stream.release()


    public function local_address() -> Result[net.SocketAddress, net.Error]:
        return this.stream.local_address()


    public function peer_address() -> Result[net.SocketAddress, net.Error]:
        return this.stream.peer_address()


    public function socket_fd() -> Result[int, net.Error]:
        return this.stream.socket_fd()


    public function max_packet_bytes() -> ptr_uint:
        return this.max_packet_bytes


    public function shutdown() -> Task[Result[bool, net.Error]]:
        return this.stream.shutdown()


    public async function write_packet(content: span[ubyte]) -> Result[ptr_uint, Error]:
        if content.len > this.max_packet_bytes:
            return Result[ptr_uint, Error].failure(error = packet_error(-2, "packet exceeds configured maximum"))

        if content.len > max_frame_payload_bytes:
            return Result[ptr_uint, Error].failure(error = packet_error(-3, "packet exceeds 32-bit frame limit"))

        var framed = frame_bytes(content)
        defer framed.release()

        let write_result = await this.stream.write_bytes(framed.as_span())
        match write_result:
            Result.failure as error_payload:
                return Result[ptr_uint, Error].failure(error = error_from_net(error_payload.error))
            Result.success as write_payload:
                unsafe: write_payload.value
                return Result[ptr_uint, Error].success(value = content.len)


    public async function read_packet() -> Result[bytes.Bytes, Error]:
        let header_result = await this.stream.read_exactly(frame_header_bytes)
        match header_result:
            Result.failure as payload:
                return Result[bytes.Bytes, Error].failure(error = error_from_net(payload.error))
            Result.success as payload:
                var header = payload.value
                defer header.release()
                let packet_length = decode_packet_length(header)
                if packet_length > this.max_packet_bytes:
                    let discard_result = await discard_exactly(this.stream, packet_length)
                    match discard_result:
                        Result.failure as discard_payload:
                            return Result[bytes.Bytes, Error].failure(error = discard_payload.error)
                        Result.success as discard_payload:
                            unsafe: discard_payload.value
                            return Result[bytes.Bytes, Error].failure(error = packet_error(-2, "packet exceeds configured maximum"))

                let payload_result = await this.stream.read_exactly(packet_length)
                match payload_result:
                    Result.failure as read_payload:
                        return Result[bytes.Bytes, Error].failure(error = error_from_net(read_payload.error))
                    Result.success as read_payload:
                        return Result[bytes.Bytes, Error].success(value = read_payload.value)


extending Listener:
    public mutable function release() -> void:
        this.listener.release()


    public function local_address() -> Result[net.SocketAddress, net.Error]:
        return this.listener.local_address()


    public function max_packet_bytes() -> ptr_uint:
        return this.max_packet_bytes


    public async function accept() -> Result[Stream, Error]:
        let accept_result = await this.listener.accept()
        match accept_result:
            Result.failure as payload:
                return Result[Stream, Error].failure(error = error_from_net(payload.error))
            Result.success as payload:
                return Result[Stream, Error].success(value = wrap(payload.value, this.max_packet_bytes))
