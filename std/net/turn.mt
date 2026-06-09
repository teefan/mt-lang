import std.async as aio
import std.binary as bin
import std.bytes as bytes
import std.crypto as crypto
import std.fmt as fmt
import std.libuv as libuv
import std.net as net
import std.string as string

const stun_magic_cookie: uint = 0x2112A442

const allocate_request: ushort = 0x0003
const allocate_success: ushort = 0x0103
const allocate_error: ushort = 0x0113
const send_indication: ushort = 0x0016
const data_indication: ushort = 0x0017

const attr_xor_relayed_address: ushort = 0x0016
const attr_xor_peer_address: ushort = 0x0017
const attr_data: ushort = 0x0012
const attr_requested_transport: ushort = 0x0019

const turn_header_len: ptr_uint = 20

const err_tid_failed: int = -1
const err_send_failed: int = -2
const err_recv_failed: int = -3
const err_allocate_rejected: int = -4
const err_timeout: int = -5
const err_parse_failed: int = -6
const err_invalid_address: int = -7
const err_no_data_attribute: int = -8

public struct TurnAllocation:
    relay_address: net.SocketAddress

public struct TurnDatagram:
    peer_address: net.SocketAddress
    data: bytes.Bytes

public struct Error:
    code: int
    message: string.String


extending Error:
    public editable function release() -> void:
        this.message.release()


extending TurnAllocation:
    public editable function release() -> void:
        this.relay_address.release()


extending TurnDatagram:
    public editable function release() -> void:
        this.peer_address.release()
        this.data.release()


function turn_error(code: int, msg: str) -> Error:
    return Error(code = code, message = string.String.from_str(msg))


function read_u16_be(data: span[ubyte], offset: ptr_uint) -> ushort:
    let hi = uint<-data[offset]
    let lo = uint<-data[offset + ptr_uint<-1]
    return ushort<-((hi << 8) | lo)


function read_u32_be(data: span[ubyte], offset: ptr_uint) -> uint:
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


function transaction_id_from_bytes(data: bytes.Bytes) -> array[ubyte, 12]:
    let span = data.as_span()
    var tid = zero[array[ubyte, 12]]
    var i: ptr_uint = 0
    while i < ptr_uint<-12:
        tid[i] = span[i]
        i += 1
    return tid


public function build_allocate_request(tid: array[ubyte, 12]) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(turn_header_len + ptr_uint<-8)

    w.write_u8(0x00)
    w.write_u8(0x03)
    w.write_u8(0x00)
    w.write_u8(0x08)

    w.write_u8(0x21)
    w.write_u8(0x12)
    w.write_u8(0xA4)
    w.write_u8(0x42)

    var i: ptr_uint = 0
    while i < ptr_uint<-12:
        w.write_u8(tid[i])
        i += 1

    w.write_u8(0x00)
    w.write_u8(0x19)
    w.write_u8(0x00)
    w.write_u8(0x04)
    w.write_u8(0x11)
    w.write_u8(0x00)
    w.write_u8(0x00)
    w.write_u8(0x00)

    return w.finish()


public function parse_allocate_response(
    packet: bytes.Bytes,
    expected_tid: array[ubyte, 12]
) -> Result[TurnAllocation, Error]:
    let data = packet.as_span()
    if data.len < turn_header_len:
        return Result[TurnAllocation, Error].failure(
            error = turn_error(err_parse_failed, "packet too small for TURN header")
        )

    let msg_type = read_u16_be(data, ptr_uint<-0)
    if msg_type == allocate_error:
        return Result[TurnAllocation, Error].failure(
            error = turn_error(err_allocate_rejected, "server rejected allocation")
        )
    if msg_type != allocate_success:
        return Result[TurnAllocation, Error].failure(
            error = turn_error(err_parse_failed, "not an allocate success response")
        )

    let cookie = read_u32_be(data, ptr_uint<-4)
    if cookie != stun_magic_cookie:
        return Result[TurnAllocation, Error].failure(
            error = turn_error(err_parse_failed, "invalid magic cookie")
        )

    var j: ptr_uint = 0
    while j < ptr_uint<-12:
        if data[ptr_uint<-8 + j] != expected_tid[j]:
            return Result[TurnAllocation, Error].failure(
                error = turn_error(err_parse_failed, "transaction ID mismatch")
            )
        j += 1

    var attr_len: ptr_uint = ptr_uint<-read_u16_be(data, ptr_uint<-2)
    var offset: ptr_uint = turn_header_len
    while attr_len >= ptr_uint<-4:
        if offset + ptr_uint<-4 > data.len:
            break
        let attr_type = read_u16_be(data, offset)
        let alen = ptr_uint<-read_u16_be(data, offset + ptr_uint<-2)
        let padded = (alen + ptr_uint<-3) & (~ptr_uint<-3)
        if offset + ptr_uint<-4 + alen > data.len:
            break

        if attr_type == attr_xor_relayed_address and alen >= ptr_uint<-8:
            let family = data[offset + ptr_uint<-5]
            if family == 0x01:
                let xport = read_u16_be(data, offset + ptr_uint<-6)
                let port = xport ^ ushort<-((stun_magic_cookie >> uint<-16) & uint<-0xFFFF)
                let xaddr = read_u32_be(data, offset + ptr_uint<-8)
                let ip = xaddr ^ stun_magic_cookie
                var ip_str = format_ipv4(ip)
                defer ip_str.release()
                let addr_result = net.ipv4(ip_str.as_str(), int<-port)
                match addr_result:
                    Result.success as ap:
                        return Result[TurnAllocation, Error].success(
                            value = TurnAllocation(relay_address = ap.value)
                        )
                    Result.failure:
                        pass

        offset = offset + ptr_uint<-4 + padded
        attr_len = attr_len - ptr_uint<-4 - padded

    return Result[TurnAllocation, Error].failure(
        error = turn_error(err_parse_failed, "no XOR-RELAYED-ADDRESS found")
    )


public async function allocate(
    socket: net.UdpSocket,
    turn_server: net.SocketAddress
) -> Result[TurnAllocation, Error]:
    let rand_result = crypto.random_bytes(12)
    match rand_result:
        Result.failure:
            return Result[TurnAllocation, Error].failure(
                error = turn_error(err_tid_failed, "failed to generate transaction ID")
            )
        Result.success as rp:
            var tid = transaction_id_from_bytes(rp.value)
            rp.value.release()
            var request = build_allocate_request(tid)
            defer request.release()
            let send_result = await socket.send_to(request.as_span(), turn_server)
            match send_result:
                Result.failure:
                    return Result[TurnAllocation, Error].failure(
                        error = turn_error(err_send_failed, "failed to send allocate request")
                    )
                Result.success:
                    pass

            var frame: uint = 0
            var recv_task = socket.recv_from(512)
            while frame < 40:
                if aio.completed(recv_task):
                    let recv_result = aio.result(recv_task)
                    match recv_result:
                        Result.failure:
                            return Result[TurnAllocation, Error].failure(
                                error = turn_error(err_recv_failed, "recv failed")
                            )
                        Result.success as dp:
                            var datagram = dp.value
                            let parse_result = parse_allocate_response(datagram.data, tid)
                            datagram.data.release()
                            datagram.source.release()
                            match parse_result:
                                Result.failure:
                                    continue
                                Result.success as ap:
                                    return Result[TurnAllocation, Error].success(value = ap.value)
                await aio.sleep(50)
                frame += 1

            return Result[TurnAllocation, Error].failure(
                error = turn_error(err_timeout, "allocate request timed out")
            )


function addr_to_raw_ipv4(addr: net.SocketAddress) -> uint:
    let storage = addr.storage else:
        return 0
    let in_ptr = unsafe: ptr[libuv.sockaddr_in]<-storage
    return (unsafe: read(in_ptr)).sin_addr


public function build_send_indication(
    tid: array[ubyte, 12],
    peer: net.SocketAddress,
    data: span[ubyte]
) -> Result[bytes.Bytes, Error]:
    let port_result = peer.port()
    match port_result:
        Result.failure:
            return Result[bytes.Bytes, Error].failure(
                error = turn_error(err_invalid_address, "failed to get peer port")
            )
        Result.success as pp:
            let host_port = pp.value
            let xport = ushort<-host_port ^ ushort<-((stun_magic_cookie >> uint<-16) & uint<-0xFFFF)
            let ip_raw = addr_to_raw_ipv4(peer)
            let xip = ip_raw ^ stun_magic_cookie

            let data_len = data.len
            let attr_total: ptr_uint = ptr_uint<-12 + data_len
            var w = bin.Writer.with_capacity(turn_header_len + attr_total)

            w.write_u8(0x00)
            w.write_u8(0x16)
            w.write_u8(ubyte<-((ushort<-attr_total >> 8) & 0xFF))
            w.write_u8(ubyte<-(ushort<-attr_total & 0xFF))
            w.write_u8(0x21)
            w.write_u8(0x12)
            w.write_u8(0xA4)
            w.write_u8(0x42)
            var i: ptr_uint = 0
            while i < ptr_uint<-12:
                w.write_u8(tid[i])
                i += 1

            w.write_u8(0x00)
            w.write_u8(0x17)
            w.write_u8(0x00)
            w.write_u8(0x08)
            w.write_u8(0x00)
            w.write_u8(0x01)
            w.write_u8(ubyte<-((xport >> 8) & 0xFF))
            w.write_u8(ubyte<-(xport & 0xFF))
            w.write_u8(ubyte<-((xip >> 24) & 0xFF))
            w.write_u8(ubyte<-((xip >> 16) & 0xFF))
            w.write_u8(ubyte<-((xip >> 8) & 0xFF))
            w.write_u8(ubyte<-(xip & 0xFF))

            w.write_u8(0x00)
            w.write_u8(0x12)
            w.write_u8(ubyte<-((ushort<-data_len >> 8) & 0xFF))
            w.write_u8(ubyte<-(ushort<-data_len & 0xFF))
            var j: ptr_uint = 0
            while j < data_len:
                w.write_u8(data[j])
                j += 1

            return Result[bytes.Bytes, Error].success(value = w.finish())


public function parse_data_indication(
    packet: bytes.Bytes
) -> Result[TurnDatagram, Error]:
    let data = packet.as_span()
    if data.len < turn_header_len:
        return Result[TurnDatagram, Error].failure(
            error = turn_error(err_parse_failed, "packet too small")
        )

    let msg_type = read_u16_be(data, ptr_uint<-0)
    if msg_type != data_indication:
        return Result[TurnDatagram, Error].failure(
            error = turn_error(err_parse_failed, "not a data indication")
        )

    var attr_len: ptr_uint = ptr_uint<-read_u16_be(data, ptr_uint<-2)
    var offset: ptr_uint = turn_header_len
    var found_peer: bool = false
    var peer_addr: net.SocketAddress = zero[net.SocketAddress]
    var found_data: bool = false
    var payload: bytes.Bytes = bytes.Bytes.empty()

    while attr_len >= ptr_uint<-4:
        if offset + ptr_uint<-4 > data.len:
            break
        let attr_type = read_u16_be(data, offset)
        let alen = ptr_uint<-read_u16_be(data, offset + ptr_uint<-2)
        let padded = (alen + ptr_uint<-3) & (~ptr_uint<-3)
        if offset + ptr_uint<-4 + alen > data.len:
            break

        if attr_type == attr_xor_peer_address and alen >= ptr_uint<-8:
            let family = data[offset + ptr_uint<-5]
            if family == 0x01:
                let xport = read_u16_be(data, offset + ptr_uint<-6)
                let port = xport ^ ushort<-((stun_magic_cookie >> uint<-16) & uint<-0xFFFF)
                let xaddr = read_u32_be(data, offset + ptr_uint<-8)
                let ip = xaddr ^ stun_magic_cookie
                var ip_str = format_ipv4(ip)
                defer ip_str.release()
                let addr_result = net.ipv4(ip_str.as_str(), int<-port)
                match addr_result:
                    Result.success as ap:
                        peer_addr = ap.value
                        found_peer = true
                    Result.failure:
                        pass

        if attr_type == attr_data and alen > ptr_uint<-0:
            var buf = bin.Writer.with_capacity(alen)
            var k: ptr_uint = 0
            while k < alen:
                buf.write_u8(data[offset + ptr_uint<-4 + k])
                k += 1
            payload = buf.finish()
            found_data = true

        offset = offset + ptr_uint<-4 + padded
        attr_len = attr_len - ptr_uint<-4 - padded

    if not found_peer or not found_data:
        if found_data:
            payload.release()
        return Result[TurnDatagram, Error].failure(
            error = turn_error(err_no_data_attribute, "data indication missing attributes")
        )

    return Result[TurnDatagram, Error].success(
        value = TurnDatagram(peer_address = peer_addr, data = payload)
    )


public async function send_data(
    socket: net.UdpSocket,
    turn_server: net.SocketAddress,
    peer: net.SocketAddress,
    payload: span[ubyte]
) -> Result[ptr_uint, Error]:
    let rand_result = crypto.random_bytes(12)
    match rand_result:
        Result.failure:
            return Result[ptr_uint, Error].failure(
                error = turn_error(err_tid_failed, "failed to generate transaction ID")
            )
        Result.success as rp:
            var tid = transaction_id_from_bytes(rp.value)
            rp.value.release()
            let build_result = build_send_indication(tid, peer, payload)
            match build_result:
                Result.failure as bp:
                    return Result[ptr_uint, Error].failure(error = bp.error)
                Result.success as bp:
                    var packet = bp.value
                    defer packet.release()
                    let send_result = await socket.send_to(packet.as_span(), turn_server)
                    match send_result:
                        Result.failure as sp:
                            return Result[ptr_uint, Error].failure(
                                error = turn_error(err_send_failed, "send indication failed")
                            )
                        Result.success as nrp:
                            return Result[ptr_uint, Error].success(value = nrp.value)


public async function recv_data(
    socket: net.UdpSocket
) -> Result[TurnDatagram, Error]:
    var frame: uint = 0
    var recv_task = socket.recv_from(4096)
    while frame < 40:
        if aio.completed(recv_task):
            let recv_result = aio.result(recv_task)
            match recv_result:
                Result.failure:
                    return Result[TurnDatagram, Error].failure(
                        error = turn_error(err_recv_failed, "recv failed")
                    )
                Result.success as dp:
                    var datagram = dp.value
                    let parse_result = parse_data_indication(datagram.data)
                    datagram.data.release()
                    datagram.source.release()
                    match parse_result:
                        Result.failure:
                            continue
                        Result.success as tp:
                            return Result[TurnDatagram, Error].success(value = tp.value)
        await aio.sleep(50)
        frame += 1

    return Result[TurnDatagram, Error].failure(
        error = turn_error(err_timeout, "recv from relay timed out")
    )
