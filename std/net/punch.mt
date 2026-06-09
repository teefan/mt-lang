import std.async as aio
import std.binary as bin
import std.bytes as bytes
import std.net as net
import std.string as string
import std.vec as vec

const punch_magic: array[ubyte, 4] = array[ubyte, 4](0x4D, 0x54, 0x50, 0x43)

const burst_count: uint = 3
const burst_delay: ptr_uint = 20
const timeout_frames: uint = 120

const err_send_failed: int = -1
const err_recv_failed: int = -2
const err_no_response: int = -3
const err_wrong_source: int = -4

public enum CandidateKind: ubyte
    local = 0
    server_reflexive = 1

public struct Candidate:
    address: net.SocketAddress
    kind: CandidateKind

public struct PunchResult:
    address: net.SocketAddress

public struct Error:
    code: int
    message: string.String


extending Error:
    public editable function release() -> void:
        this.message.release()


extending Candidate:
    public editable function release() -> void:
        this.address.release()


extending PunchResult:
    public editable function release() -> void:
        this.address.release()


function punch_error(code: int, msg: str) -> Error:
    return Error(code = code, message = string.String.from_str(msg))


function matches_any_candidate(source: net.SocketAddress, candidates: vec.Vec[Candidate]) -> bool:
    var i: ptr_uint = 0
    while i < candidates.len:
        let cand_ptr = candidates.get(i) else:
            break
        if source.equal(unsafe: read(cand_ptr).address):
            return true
        i += 1
    return false


public function build_punch_probe() -> bytes.Bytes:
    var w = bin.Writer.with_capacity(4)
    w.write_u8(punch_magic[0])
    w.write_u8(punch_magic[1])
    w.write_u8(punch_magic[2])
    w.write_u8(punch_magic[3])
    return w.finish()


public function is_punch_probe(data: span[ubyte]) -> bool:
    if data.len < ptr_uint<-4:
        return false
    return data[0] == punch_magic[0] and data[1] == punch_magic[1] and data[2] == punch_magic[2] and data[3] == punch_magic[3]


public async function punch(
    socket: net.UdpSocket,
    remote_candidates: vec.Vec[Candidate]
) -> Result[PunchResult, Error]:
    var probe = build_punch_probe()
    defer probe.release()

    var recv_task = socket.recv_from(512)

    var c: uint = 0
    while c < burst_count:
        var i: ptr_uint = 0
        while i < remote_candidates.len:
            let cand_ptr = remote_candidates.get(i) else:
                break
            let send_result = await socket.send_to(probe.as_span(), unsafe: read(cand_ptr).address)
            match send_result:
                Result.failure as sp:
                    return Result[PunchResult, Error].failure(
                        error = punch_error(err_send_failed, "burst send failed")
                    )
                Result.success:
                    pass
            i += 1

        if aio.completed(recv_task):
            let recv_result = aio.result(recv_task)
            match recv_result:
                Result.failure:
                    return Result[PunchResult, Error].failure(
                        error = punch_error(err_recv_failed, "recv failed")
                    )
                Result.success as dp:
                    var datagram = dp.value
                    defer datagram.data.release()
                    defer datagram.source.release()
                    if is_punch_probe(datagram.data.as_span()):
                        if not matches_any_candidate(datagram.source, remote_candidates):
                            return Result[PunchResult, Error].failure(
                                error = punch_error(err_wrong_source, "response from unexpected address")
                            )
                        let addr_copy = datagram.source.copy()
                        match addr_copy:
                            Result.success as ac:
                                return Result[PunchResult, Error].success(
                                    value = PunchResult(address = ac.value)
                                )
                            Result.failure:
                                pass

        if c < burst_count - 1:
            await aio.sleep(burst_delay)
        c += 1

    var frame: uint = 0
    while frame < timeout_frames:
        if aio.completed(recv_task):
            let recv_result = aio.result(recv_task)
            match recv_result:
                Result.failure:
                    return Result[PunchResult, Error].failure(
                        error = punch_error(err_recv_failed, "recv failed")
                    )
                Result.success as dp:
                    var datagram = dp.value
                    defer datagram.data.release()
                    defer datagram.source.release()
                    if is_punch_probe(datagram.data.as_span()):
                        if not matches_any_candidate(datagram.source, remote_candidates):
                            return Result[PunchResult, Error].failure(
                                error = punch_error(err_wrong_source, "response from unexpected address")
                            )
                        let addr_copy = datagram.source.copy()
                        match addr_copy:
                            Result.success as ac:
                                return Result[PunchResult, Error].success(
                                    value = PunchResult(address = ac.value)
                                )
                            Result.failure:
                                pass
        await aio.sleep(50)
        frame += 1

    return Result[PunchResult, Error].failure(
        error = punch_error(err_no_response, "no punch response received")
    )
