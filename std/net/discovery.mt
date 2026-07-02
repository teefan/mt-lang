import std.async as aio
import std.binary as bin
import std.bytes as bytes
import std.net as net
import std.string as string
import std.vec as vec

const discovery_magic: array[ubyte, 4] = array[ubyte, 4](
    ubyte<-0x4D, ubyte<-0x54, ubyte<-0x44, ubyte<-0x53
)

const probe_bytes: ptr_uint = 4
const min_response_bytes: ptr_uint = 11
const default_discovery_port_offset: int = 1

public struct ServerInfo:
    address: net.SocketAddress
    game_port: int
    player_count: ubyte
    max_players: ubyte
    game_name: string.String


extending ServerInfo:
    public editable function release() -> void:
        this.address.release()
        this.game_name.release()


public function build_probe() -> bytes.Bytes:
    var w = bin.Writer.with_capacity(probe_bytes)
    w.write_ubyte(discovery_magic[0])
    w.write_ubyte(discovery_magic[1])
    w.write_ubyte(discovery_magic[2])
    w.write_ubyte(discovery_magic[3])
    return w.finish()


public function build_response(
    game_port: int,
    player_count: ubyte,
    max_players: ubyte,
    game_name: str
) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(probe_bytes + 6z + game_name.len)
    w.write_ubyte(discovery_magic[0])
    w.write_ubyte(discovery_magic[1])
    w.write_ubyte(discovery_magic[2])
    w.write_ubyte(discovery_magic[3])
    w.write_ushort(ushort<-game_port)
    w.write_ubyte(player_count)
    w.write_ubyte(max_players)
    w.write_str(game_name)
    return w.finish()


function is_probe(data: span[ubyte]) -> bool:
    if data.len < probe_bytes:
        return false
    return (
        data[0] == discovery_magic[0]
        and data[1] == discovery_magic[1]
        and data[2] == discovery_magic[2]
        and data[3] == discovery_magic[3]
    )


function discovery_error(message: str) -> net.Error:
    return net.net_error(message)


function parse_response(data: span[ubyte]) -> Result[ServerInfo, net.Error]:
    if data.len < min_response_bytes:
        return Result[ServerInfo, net.Error].failure(
            error = discovery_error("discovery response too short")
        )

    if (
        data[0] != discovery_magic[0]
        or data[1] != discovery_magic[1]
        or data[2] != discovery_magic[2]
        or data[3] != discovery_magic[3]
    ):
        return Result[ServerInfo, net.Error].failure(
            error = discovery_error("discovery response bad magic")
        )

    var r = bin.reader(data)

    var _bp = r.read_bytes(probe_bytes).map_error(proc(_: bin.Error) -> net.Error:
        discovery_error("discovery response malformed header")
    )?
    _bp.release()

    var game_port: int = 0
    game_port = r.read_ushort().map_error(proc(_: bin.Error) -> net.Error:
        discovery_error("discovery response malformed port")
    )?

    var player_count: ubyte = 0
    player_count = r.read_ubyte().map_error(proc(_: bin.Error) -> net.Error:
        discovery_error("discovery response malformed player_count")
    )?

    var max_players: ubyte = 0
    max_players = r.read_ubyte().map_error(proc(_: bin.Error) -> net.Error:
        discovery_error("discovery response malformed max_players")
    )?

    let game_name = r.read_str().map_error(proc(_: bin.Error) -> net.Error:
        discovery_error("discovery response malformed name")
    )?
    return Result[ServerInfo, net.Error].success(value = ServerInfo(
        address = zero[net.SocketAddress],
        game_port = game_port,
        player_count = player_count,
        max_players = max_players,
        game_name = game_name
    ))


public async function announce(
    game_port: int,
    max_players: ubyte,
    game_name: str
) -> void:
    let discovery_port = game_port + default_discovery_port_offset
    match net.ipv4("0.0.0.0", discovery_port):
        Result.failure:
            return
        Result.success as addr_p:
            var announce_addr = addr_p.value
            defer announce_addr.release()

            match net.udp_bind(announce_addr):
                Result.failure:
                    return
                Result.success as bp:
                    var socket = bp.value
                    defer socket.release()

                    var response = build_response(game_port, ubyte<-0, max_players, game_name)
                    defer response.release()

                    while true:
                        let recv_task = socket.recv_from(1500)
                        var frame: uint = 0
                        while frame < 120:
                            if aio.completed(recv_task):
                                let recv_result = aio.result(recv_task)
                                match recv_result:
                                    Result.success as dp:
                                        var datagram = dp.value
                                        if is_probe(datagram.data.as_span()):
                                            let _ = await socket.send_to(
                                                response.as_span(),
                                                datagram.source
                                            )
                                        datagram.data.release()
                                        datagram.source.release()
                                        break
                                    Result.failure:
                                        break
                            await aio.sleep(100)
                            frame += 1


public async function discover_on(
    runtime: aio.Runtime,
    game_port: int,
    timeout_frames: uint
) -> Result[vec.Vec[ServerInfo], net.Error]:
    match net.ipv4("0.0.0.0", 0):
        Result.failure:
            return Result[vec.Vec[ServerInfo], net.Error].failure(
                error = discovery_error("failed to create local address")
            )
        Result.success as la:
            var local_addr = la.value
            defer local_addr.release()

            match net.udp_bind_on(runtime, local_addr):
                Result.failure:
                    return Result[vec.Vec[ServerInfo], net.Error].failure(
                        error = discovery_error("failed to bind discovery socket")
                    )
                Result.success as bp:
                    var socket = bp.value
                    defer socket.release()

                    match socket.set_broadcast(true):
                        0:
                            pass
                        _:
                            return Result[vec.Vec[ServerInfo], net.Error].failure(
                                error = discovery_error("failed to enable broadcast")
                            )

                    let broadcast_addr_result = net.ipv4(
                        "255.255.255.255",
                        game_port + default_discovery_port_offset
                    )
                    match broadcast_addr_result:
                        Result.failure:
                            return Result[vec.Vec[ServerInfo], net.Error].failure(
                                error = discovery_error("failed to create broadcast address")
                            )
                        Result.success as broad_addr:
                            var broadcast_addr = broad_addr.value
                            defer broadcast_addr.release()

                            var probe = build_probe()
                            defer probe.release()

                            var results = vec.Vec[ServerInfo].create()

                            var burst: uint = 0
                            while burst < 3:
                                let _ = await socket.send_to(probe.as_span(), broadcast_addr)
                                burst += 1

                            var recv_task = socket.recv_from(1500)
                            var frame: uint = 0
                            while frame < timeout_frames:
                                if aio.completed(recv_task):
                                    let recv_result = aio.result(recv_task)
                                    match recv_result:
                                        Result.success as dp:
                                            var datagram = dp.value
                                            let parse_result = parse_response(
                                                datagram.data.as_span()
                                            )
                                            datagram.data.release()
                                            match parse_result:
                                                Result.success as sp:
                                                    var info = sp.value
                                                    info.address = datagram.source
                                                    datagram.source = zero[net.SocketAddress]
                                                    if not already_discovered(
                                                        ref_of(results),
                                                        ref_of(info)
                                                    ):
                                                        results.push(info)
                                                    else:
                                                        info.release()
                                                Result.failure:
                                                    datagram.source.release()
                                        Result.failure:
                                            break
                                    recv_task = socket.recv_from(1500)
                                await aio.sleep(50)
                                frame += 1

                            return Result[vec.Vec[ServerInfo], net.Error].success(
                                value = results
                            )


public async function discover(
    game_port: int,
    timeout_frames: uint
) -> Result[vec.Vec[ServerInfo], net.Error]:
    return await discover_on(aio.current_runtime(), game_port, timeout_frames)


function already_discovered(
    results: ref[vec.Vec[ServerInfo]],
    info: ref[ServerInfo]
) -> bool:
    var index: ptr_uint = 0
    while index < results.len():
        let existing_ptr = results.get(index) else:
            break
        if unsafe: read(existing_ptr).address.equal(info.address):
            return true
        index += 1
    return false
