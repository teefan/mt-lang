import std.async as aio
import std.binary as bin
import std.bytes as bytes
import std.crypto as crypto
import std.fmt as fmt
import std.net as net
import std.string as string

const google_stun: str = "stun.l.google.com"
const google_stun_port: int = 19302

const stun_magic_cookie: uint = 0x2112A442
const stun_header_len: ptr_uint = 20

const err_tid_failed: int = -1
const err_packet_too_small: int = -2
const err_not_binding_response: int = -3
const err_bad_cookie: int = -4
const err_tid_mismatch: int = -5
const err_no_xor_address: int = -6
const err_address_failed: int = -7
const err_send_failed: int = -8
const err_recv_failed: int = -9
const err_timeout: int = -10
const err_bind_failed: int = -11

public struct StunResult:
    public_address: net.SocketAddress

public struct Error:
    code: int
    message: string.String


extending Error:
    public editable function release() -> void:
        this.message.release()


extending StunResult:
    public editable function release() -> void:
        this.public_address.release()


function stun_error(code: int, msg: str) -> Error:
    return Error(code = code, message = string.String.from_str(msg))


function transaction_id_from_bytes(data: bytes.Bytes) -> array[ubyte, 12]:
    let span = data.as_span()
    var tid = zero[array[ubyte, 12]]
    var i: ptr_uint = 0
    while i < ptr_uint<-12:
        tid[i] = span[i]
        i += 1
    return tid


public function build_binding_request(tid: array[ubyte, 12]) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(stun_header_len)
    w.write_ubyte(0x00)
    w.write_ubyte(0x01)
    w.write_ubyte(0x00)
    w.write_ubyte(0x00)
    w.write_ubyte(0x21)
    w.write_ubyte(0x12)
    w.write_ubyte(0xA4)
    w.write_ubyte(0x42)
    var i: ptr_uint = 0
    while i < ptr_uint<-12:
        w.write_ubyte(tid[i])
        i += 1
    return w.finish()


function read_ushort_be(data: span[ubyte], offset: ptr_uint) -> ushort:
    let hi = uint<-data[offset]
    let lo = uint<-data[offset + ptr_uint<-1]
    return ushort<-((hi << 8) | lo)


function read_uint_be(data: span[ubyte], offset: ptr_uint) -> uint:
    let b0 = uint<-data[offset]
    let b1 = uint<-data[offset + ptr_uint<-1]
    let b2 = uint<-data[offset + ptr_uint<-2]
    let b3 = uint<-data[offset + ptr_uint<-3]
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3


function format_ipv4(addr: uint) -> string.String:
    let a = uint<-(addr & uint<-0xFF)
    let b = uint<-((addr >> uint<-8) & uint<-0xFF)
    let c = uint<-((addr >> uint<-16) & uint<-0xFF)
    let d = uint<-((addr >> uint<-24) & uint<-0xFF)
    var s = string.String.with_capacity(16)
    fmt.append_uint(ref_of(s), d)
    s.append(".")
    fmt.append_uint(ref_of(s), c)
    s.append(".")
    fmt.append_uint(ref_of(s), b)
    s.append(".")
    fmt.append_uint(ref_of(s), a)
    let result = string.String.from_str(s.as_str())
    s.release()
    return result


public function parse_binding_response(
    packet: bytes.Bytes,
    expected_tid: array[ubyte, 12]
) -> Result[StunResult, Error]:
    let data = packet.as_span()
    if data.len < stun_header_len:
        return Result[StunResult, Error].failure(error = stun_error(
            err_packet_too_small,
            "packet too small for STUN header"
        ))

    let msg_type = read_ushort_be(data, ptr_uint<-0)
    if msg_type != 0x0101:
        return Result[StunResult, Error].failure(error = stun_error(
            err_not_binding_response,
            "not a binding success response"
        ))

    var attr_len: ptr_uint = ptr_uint<-read_ushort_be(data, ptr_uint<-2)
    let cookie = read_uint_be(data, ptr_uint<-4)
    if cookie != stun_magic_cookie:
        return Result[StunResult, Error].failure(error = stun_error(err_bad_cookie, "invalid magic cookie"))

    var j: ptr_uint = 0
    while j < ptr_uint<-12:
        if data[ptr_uint<-8 + j] != expected_tid[j]:
            return Result[StunResult, Error].failure(error = stun_error(err_tid_mismatch, "transaction ID mismatch"))
        j += 1

    var offset: ptr_uint = stun_header_len
    while attr_len >= ptr_uint<-4:
        if offset + ptr_uint<-4 > data.len:
            break
        let attr_type = read_ushort_be(data, offset)
        let alen = ptr_uint<-read_ushort_be(data, offset + ptr_uint<-2)
        let padded = (alen + ptr_uint<-3) & (~ptr_uint<-3)
        if offset + ptr_uint<-4 + alen > data.len:
            break

        if attr_type == 0x0020 and alen >= ptr_uint<-8 and data[offset + ptr_uint<-5] == 0x01:
            let xport = read_ushort_be(data, offset + ptr_uint<-6)
            let port = xport ^ ushort<-((stun_magic_cookie >> uint<-16) & uint<-0xFFFF)
            let xaddr = read_uint_be(data, offset + ptr_uint<-8)
            let ip = xaddr ^ stun_magic_cookie
            var ip_str = format_ipv4(ip)
            defer ip_str.release()
            let addr_result = net.ipv4(ip_str.as_str(), int<-port)
            match addr_result:
                Result.failure:
                    return Result[StunResult, Error].failure(error = stun_error(
                        err_address_failed,
                        "failed to construct address"
                    ))
                Result.success as addr_payload:
                    return Result[StunResult, Error].success(value = StunResult(public_address = addr_payload.value))

        offset = offset + ptr_uint<-4 + padded
        attr_len = attr_len - ptr_uint<-4 - padded

    return Result[StunResult, Error].failure(error = stun_error(
        err_no_xor_address,
        "no XOR-MAPPED-ADDRESS attribute found"
    ))


public async function resolve_public_address(
    socket: net.UdpSocket,
    stun_server: net.SocketAddress
) -> Result[StunResult, Error]:
    let rand_result = crypto.random_bytes(12)
    match rand_result:
        Result.failure:
            return Result[StunResult, Error].failure(error = stun_error(
                err_tid_failed,
                "failed to generate transaction ID"
            ))
        Result.success as rp:
            let tid = transaction_id_from_bytes(rp.value)
            rp.value.release()
            var request = build_binding_request(tid)
            defer request.release()
            let send_result = await socket.send_to(request.as_span(), stun_server)
            match send_result:
                Result.failure:
                    return Result[StunResult, Error].failure(error = stun_error(
                        err_send_failed,
                        "failed to send STUN request"
                    ))
                Result.success:
                    pass

            var frame: uint = 0
            let recv_task = socket.recv_from(512)
            while frame < 40:
                if aio.completed(recv_task):
                    let recv_result = aio.result(recv_task)
                    match recv_result:
                        Result.failure:
                            return Result[StunResult, Error].failure(error = stun_error(err_recv_failed, "recv failed"))
                        Result.success as dp:
                            var datagram = dp.value
                            let parse_result = parse_binding_response(datagram.data, tid)
                            datagram.data.release()
                            datagram.source.release()
                            match parse_result:
                                Result.failure:
                                    continue
                                Result.success as srp:
                                    return Result[StunResult, Error].success(value = srp.value)
                await aio.sleep(50)
                frame += 1

            return Result[StunResult, Error].failure(error = stun_error(err_timeout, "STUN request timed out"))


public async function resolve_public_address_on(
    runtime: aio.Runtime,
    local_addr: net.SocketAddress,
    stun_server: net.SocketAddress
) -> Result[StunResult, Error]:
    let bind_result = net.udp_bind_on(runtime, local_addr)
    match bind_result:
        Result.failure:
            return Result[StunResult, Error].failure(
                error = stun_error(err_bind_failed, "failed to bind socket")
            )
        Result.success as bp:
            var socket = bp.value
            defer socket.release()
            return await resolve_public_address(socket, stun_server)


public async function resolve(
    stun_server: net.SocketAddress
) -> Result[StunResult, Error]:
    let local_result = net.ipv4("0.0.0.0", 0)
    match local_result:
        Result.failure:
            return Result[StunResult, Error].failure(
                error = stun_error(err_bind_failed, "failed to create local address")
            )
        Result.success as la:
            var local_addr = la.value
            defer local_addr.release()
            return await resolve_public_address_on(aio.current_runtime(), local_addr, stun_server)
