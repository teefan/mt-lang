import std.async as aio
import std.binary as bin
import std.bytes as bytes
import std.libuv as libuv
import std.net as net
import std.string as string

const clock_magic: array[ubyte, 8] = array[ubyte, 8](
    ubyte<-0x4D, ubyte<-0x54, ubyte<-0x43, ubyte<-0x4C,
    ubyte<-0x4F, ubyte<-0x43, ubyte<-0x4B, ubyte<-0x00
)

const sync_request: ubyte = 0x01
const sync_response: ubyte = 0x02

const header_bytes: ptr_uint = 9
const request_bytes: ptr_uint = 17
const response_bytes: ptr_uint = 25

const err_send_failed: int = -1
const err_recv_failed: int = -2
const err_timeout: int = -3
const err_bad_packet: int = -4

public struct ClockSync:
    offset_us: int
    rtt_us: ptr_uint

public struct TickClock:
    tick: uint
    rate: uint
    epoch: ulong

public struct Error:
    code: int
    message: string.String


extending Error:
    public editable function release() -> void:
        this.message.release()


function clock_error(code: int, msg: str) -> Error:
    return Error(code = code, message = string.String.from_str(msg))


public function monotonic_ns() -> ulong:
    return libuv.hrtime()


public function monotonic_us() -> ulong:
    return libuv.hrtime() / ulong<-1000


public function build_request(t1: ulong) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(request_bytes)
    var i: ptr_uint = 0
    while i < ptr_uint<-8:
        w.write_ubyte(clock_magic[i])
        i += 1
    w.write_ubyte(sync_request)
    w.write_ulong(t1)
    return w.finish()


public function build_response(t1_client: ulong, t2_server: ulong) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(response_bytes)
    var i: ptr_uint = 0
    while i < ptr_uint<-8:
        w.write_ubyte(clock_magic[i])
        i += 1
    w.write_ubyte(sync_response)
    w.write_ulong(t1_client)
    w.write_ulong(t2_server)
    return w.finish()


function is_clock_packet(data: span[ubyte]) -> bool:
    if data.len < header_bytes:
        return false
    var i: ptr_uint = 0
    while i < ptr_uint<-8:
        if data[i] != clock_magic[i]:
            return false
        i += 1
    return true


public function parse_request(data: span[ubyte]) -> Result[ulong, Error]:
    if data.len < request_bytes or data[ptr_uint<-8] != sync_request:
        return Result[ulong, Error].failure(error = clock_error(err_bad_packet, "not a clock sync request"))
    var r = bin.reader(data)
    match r.read_bytes(ptr_uint<-9):
        Result.failure:
            return Result[ulong, Error].failure(error = clock_error(err_bad_packet, "malformed request"))
        Result.success as bp:
            bp.value.release()
    match r.read_ulong():
        Result.failure:
            return Result[ulong, Error].failure(error = clock_error(err_bad_packet, "malformed timestamp"))
        Result.success as tp:
            return Result[ulong, Error].success(value = tp.value)


public function parse_response(data: span[ubyte]) -> Result[ClockSync, Error]:
    if data.len < response_bytes or data[ptr_uint<-8] != sync_response:
        return Result[ClockSync, Error].failure(error = clock_error(err_bad_packet, "not a clock sync response"))
    var r = bin.reader(data)
    match r.read_bytes(ptr_uint<-9):
        Result.failure:
            return Result[ClockSync, Error].failure(error = clock_error(err_bad_packet, "malformed response"))
        Result.success as bp:
            bp.value.release()
    match r.read_ulong():
        Result.failure:
            return Result[ClockSync, Error].failure(error = clock_error(err_bad_packet, "malformed t1"))
        Result.success as t1_payload:
            let t1_client = t1_payload.value
            match r.read_ulong():
                Result.failure:
                    return Result[ClockSync, Error].failure(error = clock_error(err_bad_packet, "malformed t2"))
                Result.success as t2_payload:
                    let t2_svr = t2_payload.value
                    let t4 = libuv.hrtime()
                    let rtt = t4 - t1_client
                    let half_rtt = rtt / ulong<-2
                    if t2_svr > t1_client + half_rtt:
                        let offset_ns = t2_svr - t1_client - half_rtt
                        return Result[ClockSync, Error].success(
                            value = ClockSync(
                                offset_us = int<-(offset_ns / ulong<-1000),
                                rtt_us = ptr_uint<-(rtt / ulong<-1000)
                            )
                        )
                    return Result[ClockSync, Error].success(
                        value = ClockSync(offset_us = int<-0, rtt_us = ptr_uint<-(rtt / ulong<-1000))
                    )


public async function measure_offset(
    socket: net.UdpSocket,
    peer: net.SocketAddress
) -> Result[ClockSync, Error]:
    let t1 = libuv.hrtime()
    var request = build_request(t1)
    defer request.release()
    let send_result = await socket.send_to(request.as_span(), peer)
    match send_result:
        Result.failure:
            return Result[ClockSync, Error].failure(
                error = clock_error(err_send_failed, "failed to send sync request")
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
                    return Result[ClockSync, Error].failure(
                        error = clock_error(err_recv_failed, "recv failed")
                    )
                Result.success as dp:
                    var datagram = dp.value
                    defer datagram.data.release()
                    defer datagram.source.release()
                    if is_clock_packet(datagram.data.as_span()):
                        let parse_result = parse_response(datagram.data.as_span())
                        match parse_result:
                            Result.failure:
                                continue
                            Result.success as sp:
                                return Result[ClockSync, Error].success(value = sp.value)
        await aio.sleep(50)
        frame += 1

    return Result[ClockSync, Error].failure(
        error = clock_error(err_timeout, "clock sync request timed out")
    )


public async function respond_to_sync(
    socket: net.UdpSocket
) -> void:
    var recv_task = socket.recv_from(512)
    var frame: uint = 0
    while frame < 60:
        if aio.completed(recv_task):
            let recv_result = aio.result(recv_task)
            match recv_result:
                Result.success as dp:
                    var datagram = dp.value
                    defer datagram.data.release()
                    defer datagram.source.release()
                    if is_clock_packet(datagram.data.as_span()):
                        let parse_result = parse_request(datagram.data.as_span())
                        match parse_result:
                            Result.success as tp:
                                let t2 = libuv.hrtime()
                                var resp = build_response(tp.value, t2)
                                defer resp.release()
                                let _ = await socket.send_to(resp.as_span(), datagram.source)
                            Result.failure:
                                pass
                Result.failure:
                    pass
            recv_task = socket.recv_from(512)
        await aio.sleep(100)
        frame += 1


public function tick_clock_new(rate: uint) -> TickClock:
    return TickClock(tick = uint<-0, rate = rate, epoch = monotonic_ns())


public function tick_clock_from_seed(rate: uint, seed_tick: uint, epoch_ns: ulong) -> TickClock:
    return TickClock(tick = seed_tick, rate = rate, epoch = epoch_ns)


extending TickClock:
    public editable function advance() -> void:
        this.tick += 1


    public function elapsed_ticks() -> uint:
        let now = monotonic_ns()
        let elapsed_ns = now - this.epoch
        let tick_duration_ns = ulong<-(ulong<-1000000000 / ulong<-uint<-this.rate)
        if tick_duration_ns == ulong<-0:
            return uint<-0
        return uint<-(elapsed_ns / tick_duration_ns)


    public function time_to_next_tick() -> ptr_uint:
        let now = monotonic_ns()
        let elapsed_ns = now - this.epoch
        let tick_ns = ulong<-(ulong<-1000000000 / ulong<-(ulong<-uint<-this.rate))
        let into_current = elapsed_ns % tick_ns
        let remaining = tick_ns - into_current
        return ptr_uint<-(remaining / ulong<-1000)


    public function tick_ready() -> bool:
        let elapsed = this.elapsed_ticks()
        return elapsed > this.tick
