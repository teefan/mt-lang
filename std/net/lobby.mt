import std.async as aio
import std.binary as bin
import std.bytes as bytes
import std.deque as deque
import std.net as net
import std.net.mux as mux
import std.net.session as sess
import std.str as text
import std.string as string
import std.vec as vec

const lobby_channel: ubyte = 0
const type_join_request: ushort = 0x0001
const type_join_accept: ushort = 0x0002
const type_join_reject: ushort = 0x0003
const type_player_joined: ushort = 0x0004
const type_player_left: ushort = 0x0005
const type_lobby_info: ushort = 0x0006
const type_discover_request: ushort = 0x0007
const type_discover_response: ushort = 0x0008

const reject_reason_full: ubyte = 1
const reject_reason_banned: ubyte = 2
const reject_reason_invalid: ubyte = 3

public struct LobbyInfo:
    name: string.String
    player_count: ubyte
    max_players: ubyte
    player_names: vec.Vec[string.String]
    game_data: bytes.Bytes

public struct LobbyEvent:
    kind: LobbyEventKind
    player_id: uint
    player_name: string.String
    slot: ubyte
    reason: ubyte

public enum LobbyEventKind: ubyte
    player_joined = 0
    player_left = 1
    lobby_info_updated = 2
    joined = 3
    join_rejected = 4

public struct LobbyHost:
    mux: mux.MuxedSession
    info: LobbyInfo
    slots: vec.Vec[PlayerSlot]
    event_queue: deque.Deque[LobbyEvent]

struct PlayerSlot:
    player_id: uint
    player_name: string.String
    occupied: bool

public struct LobbyClient:
    mux: mux.MuxedConnection
    assigned_slot: ubyte
    assigned_id: uint
    lobby_info: LobbyInfo
    event_queue: deque.Deque[LobbyEvent]
    pending_join: bool
    pending_name: string.String

public struct Error:
    code: int
    message: string.String


function lobby_error(code: int, message: str) -> Error:
    return Error(code = code, message = string.String.from_str(message))


extending Error:
    public editable function release() -> void:
        this.message.release()


extending LobbyInfo:
    public editable function release() -> void:
        this.name.release()
        var i: ptr_uint = 0
        while i < this.player_names.len():
            let p = this.player_names.get(i) else:
                return
            unsafe: read(p).release()
            i += 1
        this.player_names.release()
        this.game_data.release()


extending LobbyEvent:
    public editable function release() -> void:
        this.player_name.release()


extending LobbyHost:
    public editable function release() -> void:
        release_lobby_queue(ref_of(this.event_queue))
        this.event_queue.release()
        release_slots(ref_of(this.slots))
        this.slots.release()
        this.info.release()
        this.mux.release()


    public function local_address() -> Result[net.SocketAddress, net.Error]:
        return this.mux.session.local_address()


    public async editable function tick(frame: uint) -> Result[bool, Error]:
        let mux_result = await this.mux.tick(frame)
        await drain_lobby_host(ref_of(this))
        match mux_result:
            Result.failure as p:
                return Result[bool, Error].failure(error = Error(code = p.error.code, message = p.error.message))
            Result.success as p:
                return Result[bool, Error].success(value = p.value)


    public editable function try_recv() -> Option[LobbyEvent]:
        return this.event_queue.pop_front()


    public function info() -> LobbyInfo:
        return this.info


    public async editable function kick_player(player_id: uint, reason: ubyte) -> Result[bool, Error]:
        match await this.mux.kick(player_id, reason):
            Result.failure as p:
                return Result[bool, Error].failure(error = Error(code = p.error.code, message = p.error.message))
            Result.success as p:
                return Result[bool, Error].success(value = p.value)


extending LobbyClient:
    public editable function release() -> void:
        release_lobby_queue(ref_of(this.event_queue))
        this.event_queue.release()
        this.lobby_info.release()
        this.pending_name.release()
        this.mux.release()


    public function state() -> sess.ConnectionState:
        return this.mux.state()


    public function assigned_slot() -> ubyte:
        return this.assigned_slot


    public function assigned_id() -> uint:
        return this.assigned_id


    public function lobby_info() -> LobbyInfo:
        return this.lobby_info


    public async editable function tick(frame: uint) -> Result[bool, Error]:
        let mux_result = await this.mux.tick(frame)
        await drain_lobby_client(ref_of(this))
        match mux_result:
            Result.failure as p:
                return Result[bool, Error].failure(error = Error(code = p.error.code, message = p.error.message))
            Result.success as p:
                return Result[bool, Error].success(value = p.value)


    public editable function try_recv() -> Option[LobbyEvent]:
        return this.event_queue.pop_front()


    public async editable function leave() -> Result[bool, Error]:
        match await this.mux.disconnect():
            Result.failure as p:
                return Result[bool, Error].failure(error = Error(code = p.error.code, message = p.error.message))
            Result.success as p:
                return Result[bool, Error].success(value = p.value)


public function create_lobby_on(
    runtime: aio.Runtime,
    local_address: net.SocketAddress,
    info: LobbyInfo,
    config: mux.MuxedConfig
) -> Result[LobbyHost, Error]:
    match mux.mux_listen_on(runtime, local_address, config):
        Result.failure as p:
            return Result[LobbyHost, Error].failure(error = Error(code = p.error.code, message = p.error.message))
        Result.success as p:
            var slots = vec.Vec[PlayerSlot].create()
            var i: ubyte = 0
            while i < info.max_players:
                slots.push(PlayerSlot(player_id = uint<-0, player_name = string.String.create(), occupied = false))
                i += 1
            var host = LobbyHost(
                mux = p.value,
                info = info,
                slots = slots,
                event_queue = deque.Deque[LobbyEvent].create()
            )
            return Result[LobbyHost, Error].success(value = host)


public function create_lobby(
    local_address: net.SocketAddress,
    info: LobbyInfo,
    config: mux.MuxedConfig
) -> Result[LobbyHost, Error]:
    return create_lobby_on(aio.current_runtime(), local_address, info, config)


public async function join_lobby_on(
    runtime: aio.Runtime,
    local_address: net.SocketAddress,
    remote_address: net.SocketAddress,
    player_name: str,
    config: mux.MuxedConfig
) -> Result[LobbyClient, Error]:
    match mux.mux_connect_on(runtime, local_address, remote_address, config):
        Result.failure as p:
            return Result[LobbyClient, Error].failure(error = Error(code = p.error.code, message = p.error.message))
        Result.success as p:
            var client = LobbyClient(
                mux = p.value,
                assigned_slot = 0,
                assigned_id = 0,
                lobby_info = LobbyInfo(
                    name = string.String.create(),
                    player_count = 0,
                    max_players = 0,
                    player_names = vec.Vec[string.String].create(),
                    game_data = bytes.Bytes.empty()
                ),
                event_queue = deque.Deque[LobbyEvent].create(),
                pending_join = true,
                pending_name = string.String.from_str(player_name)
            )
            match await client.mux.connect_to_peer():
                Result.failure as pe:
                    return Result[LobbyClient, Error].failure(error = Error(
                        code = pe.error.code,
                        message = pe.error.message
                    ))
                Result.success:
                    pass
            return Result[LobbyClient, Error].success(value = client)


public async function join_lobby(
    local_address: net.SocketAddress,
    remote_address: net.SocketAddress,
    player_name: str,
    config: mux.MuxedConfig
) -> Result[LobbyClient, Error]:
    return await join_lobby_on(aio.current_runtime(), local_address, remote_address, player_name, config)


public async function discover_lobbies_on(
    runtime: aio.Runtime,
    local_address: net.SocketAddress,
    remote_address: net.SocketAddress,
    config: mux.MuxedConfig
) -> Result[vec.Vec[LobbyInfo], Error]:
    match mux.mux_connect_on(runtime, local_address, remote_address, config):
        Result.failure as p:
            return Result[vec.Vec[LobbyInfo], Error].failure(error = Error(
                code = p.error.code,
                message = p.error.message
            ))
        Result.success as p:
            var conn = p.value
            defer conn.release()
            match await conn.connect_to_peer():
                Result.failure as pe:
                    return Result[vec.Vec[LobbyInfo], Error].failure(error = Error(
                        code = pe.error.code,
                        message = pe.error.message
                    ))
                Result.success:
                    pass

            var empty = bytes.Bytes.empty()
            let _ = await conn.mux_send(lobby_channel, type_discover_request, empty.as_span(), mux.flag_reliable)

            var frame: uint = 0
            var result = vec.Vec[LobbyInfo].create()
            while frame < 120:
                await conn.tick(frame)

                var drain_rounds: uint = 0
                while drain_rounds < 5:
                    let msg_opt = conn.try_recv()
                    match msg_opt:
                        Option.some as mp:
                            var msg = mp.value
                            if msg.channel_id == lobby_channel and msg.type_id == type_discover_response:
                                let info_result = decode_lobby_info_payload(msg.payload.as_span())
                                msg.release()
                                match info_result:
                                    Result.success as ip:
                                        result.push(ip.value)
                                    Result.failure:
                                        pass
                                var disconnect_frame: uint = 0
                                while disconnect_frame < 30:
                                    await conn.tick(frame + disconnect_frame)
                                    disconnect_frame += 1
                                return Result[vec.Vec[LobbyInfo], Error].success(value = result)
                            msg.release()
                        Option.none:
                            pass
                    drain_rounds += 1
                frame += 1

            return Result[vec.Vec[LobbyInfo], Error].success(value = result)


public async function discover_lobbies(
    local_address: net.SocketAddress,
    remote_address: net.SocketAddress,
    config: mux.MuxedConfig
) -> Result[vec.Vec[LobbyInfo], Error]:
    return await discover_lobbies_on(aio.current_runtime(), local_address, remote_address, config)


function encode_lobby_info_payload(w: ref[bin.Writer], info: ref[LobbyInfo]) -> void:
    w.write_ubyte(info.player_count)
    w.write_ubyte(info.max_players)
    w.write_str(info.name.as_str())


function decode_lobby_info_payload(data: span[ubyte]) -> Result[LobbyInfo, Error]:
    if data.len < 2:
        return Result[LobbyInfo, Error].failure(error = lobby_error(-1, "lobby info payload truncated"))
    var r = bin.reader(data)
    var player_count: ubyte = 0
    match r.read_ubyte():
        Result.failure:
            return Result[LobbyInfo, Error].failure(error = lobby_error(-1, "lobby info malformed"))
        Result.success as pc:
            player_count = pc.value
    var max_players: ubyte = 0
    match r.read_ubyte():
        Result.failure:
            return Result[LobbyInfo, Error].failure(error = lobby_error(-1, "lobby info malformed"))
        Result.success as mp:
            max_players = mp.value
    match r.read_str():
        Result.failure:
            return Result[LobbyInfo, Error].failure(error = lobby_error(-1, "lobby info malformed"))
        Result.success as sp:
            return Result[LobbyInfo, Error].success(value = LobbyInfo(
                name = sp.value,
                player_count = player_count,
                max_players = max_players,
                player_names = vec.Vec[string.String].create(),
                game_data = bytes.Bytes.empty()
            ))


function encode_string(value: str) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(4 + value.len)
    w.write_str(value)
    return w.finish()


function decode_string(data: span[ubyte]) -> Result[string.String, Error]:
    var r = bin.reader(data)
    match r.read_str():
        Result.failure:
            return Result[string.String, Error].failure(error = lobby_error(-1, "lobby malformed string"))
        Result.success as p:
            return Result[string.String, Error].success(value = p.value)


async function drain_lobby_host(host: ref[LobbyHost]) -> void:
    while true:
        let ev = host.mux.try_recv()
        match ev:
            Option.none:
                break
            Option.some as p:
                var msg = p.value
                await process_lobby_msg_host(host, ref_of(msg))


async function drain_lobby_client(client: ref[LobbyClient]) -> void:
    if client.pending_join:
        let conn_state = client.mux.state()
        if conn_state == sess.ConnectionState.connected:
            client.pending_join = false
            var encoded = encode_string(client.pending_name.as_str())
            defer encoded.release()
            let _ = await client.mux.mux_send(lobby_channel, type_join_request, encoded.as_span(), mux.flag_reliable)

    while true:
        let ev = client.mux.try_recv()
        match ev:
            Option.none:
                break
            Option.some as p:
                var msg = p.value
                process_lobby_msg_client(client, ref_of(msg))


async function process_lobby_msg_host(host: ref[LobbyHost], msg: ref[mux.MuxedMessage]) -> void:
    if msg.channel_id != lobby_channel:
        msg.release()
        return

    if msg.type_id == type_join_request:
        await handle_join_request(host, msg)
        return

    if msg.type_id == type_discover_request:
        await handle_discover_request(host, msg)
        return

    msg.release()


function process_lobby_msg_client(client: ref[LobbyClient], msg: ref[mux.MuxedMessage]) -> void:
    if msg.channel_id != lobby_channel:
        msg.release()
        return

    if msg.type_id == type_join_accept:
        handle_join_accept(client, msg)
        return

    if msg.type_id == type_join_reject:
        handle_join_reject_client(client, msg)
        return

    if msg.type_id == type_player_joined:
        handle_player_joined_client(client, msg)
        return

    if msg.type_id == type_player_left:
        handle_player_left_client(client, msg)
        return

    if msg.type_id == type_lobby_info:
        handle_lobby_info_client(client, msg)
        return

    msg.release()


async function handle_join_request(host: ref[LobbyHost], msg: ref[mux.MuxedMessage]) -> void:
    let data = msg.payload.as_span()
    let name_result = decode_string(data)
    match name_result:
        Result.failure:
            msg.release()
            return
        Result.success as name_payload:
            var player_name = name_payload.value
            defer player_name.release()

            var first_free: int = -1
            var slot_index: ubyte = 0
            while slot_index < host.info.max_players:
                let slot_ptr = host.slots.get(ptr_uint<-slot_index) else:
                    break
                if not unsafe: read(slot_ptr).occupied:
                    first_free = int<-slot_index
                    break
                slot_index += 1

            if first_free < 0:
                var reject_data = encode_join_reject(reject_reason_full)
                defer reject_data.release()
                let _ = await host.mux.mux_send(
                    msg.peer_id,
                    lobby_channel,
                    type_join_reject,
                    reject_data.as_span(),
                    mux.flag_reliable
                )
                msg.release()
                return

            let slot = ubyte<-first_free
            let slot_ptr = host.slots.get(ptr_uint<-slot) else:
                msg.release()
                return
            unsafe: read(slot_ptr).player_id = msg.peer_id
            unsafe: read(slot_ptr).player_name = string.String.from_str(player_name.as_str())
            unsafe: read(slot_ptr).occupied = true

            var accept_data = encode_join_accept(msg.peer_id, slot)
            defer accept_data.release()
            let _ = await host.mux.mux_send(
                msg.peer_id,
                lobby_channel,
                type_join_accept,
                accept_data.as_span(),
                mux.flag_reliable
            )

            let other_id = msg.peer_id
            msg.release()

            await broadcast_player_joined(host, other_id, player_name.as_str(), slot)


async function handle_discover_request(host: ref[LobbyHost], msg: ref[mux.MuxedMessage]) -> void:
    var w = bin.Writer.with_capacity(256)
    encode_lobby_info_payload(ref_of(w), host.info)
    var payload = w.finish()
    defer payload.release()
    let _ = await host.mux.mux_send(
        msg.peer_id,
        lobby_channel,
        type_discover_response,
        payload.as_span(),
        mux.flag_reliable
    )
    msg.release()


function handle_join_accept(client: ref[LobbyClient], msg: ref[mux.MuxedMessage]) -> void:
    let data = msg.payload.as_span()
    if data.len < 5:
        msg.release()
        return
    var r = bin.reader(data)
    match r.read_uint():
        Result.failure:
            msg.release()
            return
        Result.success as id_payload:
            match r.read_ubyte():
                Result.failure:
                    msg.release()
                    return
                Result.success as slot_payload:
                    client.assigned_id = id_payload.value
                    client.assigned_slot = slot_payload.value
                    msg.release()
                    client.event_queue.push_back(LobbyEvent(
                        kind = LobbyEventKind.joined,
                        player_id = id_payload.value,
                        player_name = string.String.create(),
                        slot = slot_payload.value,
                        reason = ubyte<-0
                    ))


function handle_join_reject_client(client: ref[LobbyClient], msg: ref[mux.MuxedMessage]) -> void:
    let data = msg.payload.as_span()
    var reason: ubyte = 0
    if data.len > 0:
        reason = unsafe: read(data.data)
    msg.release()
    client.event_queue.push_back(LobbyEvent(
        kind = LobbyEventKind.join_rejected,
        player_id = uint<-0,
        player_name = string.String.create(),
        slot = ubyte<-0,
        reason = reason
    ))


function handle_player_joined_client(client: ref[LobbyClient], msg: ref[mux.MuxedMessage]) -> void:
    let data = msg.payload.as_span()
    if data.len < 5:
        msg.release()
        return
    var r = bin.reader(data)
    match r.read_uint():
        Result.failure:
            msg.release()
            return
        Result.success as id_payload:
            match r.read_ubyte():
                Result.failure:
                    msg.release()
                    return
                Result.success as slot_payload:
                    let name_data = unsafe: span[ubyte](data = data.data + 5, len = data.len - 5)
                    match decode_string(name_data):
                        Result.failure:
                            msg.release()
                            return
                        Result.success as name_payload:
                            var name = name_payload.value
                            msg.release()
                            client.event_queue.push_back(LobbyEvent(
                                kind = LobbyEventKind.player_joined,
                                player_id = id_payload.value,
                                player_name = name,
                                slot = slot_payload.value,
                                reason = ubyte<-0
                            ))


function handle_player_left_client(client: ref[LobbyClient], msg: ref[mux.MuxedMessage]) -> void:
    let data = msg.payload.as_span()
    if data.len < 5:
        msg.release()
        return
    var r = bin.reader(data)
    match r.read_uint():
        Result.failure:
            msg.release()
            return
        Result.success as id_payload:
            var reason: ubyte = 0
            if data.len > 4:
                reason = unsafe: read(data.data + 4)
            msg.release()
            client.event_queue.push_back(LobbyEvent(
                kind = LobbyEventKind.player_left,
                player_id = id_payload.value,
                player_name = string.String.create(),
                slot = ubyte<-0,
                reason = reason
            ))


function handle_lobby_info_client(client: ref[LobbyClient], msg: ref[mux.MuxedMessage]) -> void:
    msg.release()
    client.event_queue.push_back(LobbyEvent(
        kind = LobbyEventKind.lobby_info_updated,
        player_id = uint<-0,
        player_name = string.String.create(),
        slot = ubyte<-0,
        reason = ubyte<-0
    ))


async function broadcast_player_joined(
    host: ref[LobbyHost],
    new_player_id: uint,
    new_player_name: str,
    slot: ubyte
) -> void:
    var w = bin.Writer.with_capacity(5 + new_player_name.len)
    w.write_uint(new_player_id)
    w.write_ubyte(slot)
    w.write_uint(uint<-new_player_name.len)
    w.write_bytes(text.as_byte_span(new_player_name))
    var payload = w.finish()
    defer payload.release()

    var peer_index: ptr_uint = 0
    let peer_count = host.mux.peer_count()
    while peer_index < peer_count:
        let peer_id = uint<-peer_index + 1
        if peer_id != new_player_id:
            let _ = await host.mux.mux_send(
                peer_id,
                lobby_channel,
                type_player_joined,
                payload.as_span(),
                mux.flag_reliable
            )
        peer_index += 1


function encode_join_accept(player_id: uint, slot: ubyte) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(5)
    w.write_uint(player_id)
    w.write_ubyte(slot)
    return w.finish()


function encode_join_reject(reason: ubyte) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(1)
    w.write_ubyte(reason)
    return w.finish()


function release_lobby_queue(queue: ref[deque.Deque[LobbyEvent]]) -> void:
    while true:
        let ev = queue.pop_front()
        match ev:
            Option.none:
                break
            Option.some as p:
                var e = p.value
                e.release()


function release_slots(slots: ref[vec.Vec[PlayerSlot]]) -> void:
    var index: ptr_uint = 0
    while index < slots.len():
        let slot_ptr = slots.get(index) else:
            return
        unsafe: read(slot_ptr).player_name.release()
        index += 1

const beacon_magic: array[ubyte, 8] = array[ubyte, 8](0x4D, 0x54, 0x4C, 0x42, 0x59, 0x00, 0x00, 0x00)

const beacon_probe_len: ptr_uint = 8
const beacon_recv_timeout: uint = 60


public function build_beacon_probe() -> bytes.Bytes:
    var w = bin.Writer.with_capacity(beacon_probe_len)
    w.write_ubyte(beacon_magic[0])
    w.write_ubyte(beacon_magic[1])
    w.write_ubyte(beacon_magic[2])
    w.write_ubyte(beacon_magic[3])
    w.write_ubyte(beacon_magic[4])
    w.write_ubyte(beacon_magic[5])
    w.write_ubyte(beacon_magic[6])
    w.write_ubyte(beacon_magic[7])
    return w.finish()


public function is_beacon_probe(data: span[ubyte]) -> bool:
    if data.len < beacon_probe_len:
        return false
    return data[0] == beacon_magic[0] and data[1] == beacon_magic[1] and data[2] == beacon_magic[2] and data[3] == beacon_magic[3]


public function build_beacon_response(info: ref[LobbyInfo]) -> bytes.Bytes:
    var w = bin.Writer.with_capacity(16)
    w.write_ubyte(beacon_magic[0])
    w.write_ubyte(beacon_magic[1])
    w.write_ubyte(beacon_magic[2])
    w.write_ubyte(beacon_magic[3])
    w.write_ubyte(beacon_magic[4])
    w.write_ubyte(beacon_magic[5])
    w.write_ubyte(beacon_magic[6])
    w.write_ubyte(beacon_magic[7])
    encode_lobby_info_payload(ref_of(w), info)
    return w.finish()


public function parse_beacon_response(data: span[ubyte]) -> Result[LobbyInfo, Error]:
    if data.len < ptr_uint<-10:
        return Result[LobbyInfo, Error].failure(
            error = lobby_error(-1, "beacon response too short")
        )
    var r = bin.reader(data)
    match r.read_bytes(beacon_probe_len):
        Result.failure:
            return Result[LobbyInfo, Error].failure(
                error = lobby_error(-1, "beacon response malformed")
            )
        Result.success as bp:
            bp.value.release()
    return decode_lobby_info_payload_offset(data, ptr_uint<-beacon_probe_len)


function decode_lobby_info_payload_offset(data: span[ubyte], offset: ptr_uint) -> Result[LobbyInfo, Error]:
    if data.len < offset + ptr_uint<-2:
        return Result[LobbyInfo, Error].failure(error = lobby_error(-1, "lobby info payload truncated"))
    var r = bin.reader(data)
    match r.read_bytes(offset):
        Result.failure:
            return Result[LobbyInfo, Error].failure(error = lobby_error(-1, "lobby info malformed"))
        Result.success:
            pass
    var player_count: ubyte = 0
    match r.read_ubyte():
        Result.failure:
            return Result[LobbyInfo, Error].failure(error = lobby_error(-1, "lobby info malformed"))
        Result.success as pc:
            player_count = pc.value
    var max_players: ubyte = 0
    match r.read_ubyte():
        Result.failure:
            return Result[LobbyInfo, Error].failure(error = lobby_error(-1, "lobby info malformed"))
        Result.success as mp:
            max_players = mp.value
    match r.read_str():
        Result.failure:
            return Result[LobbyInfo, Error].failure(error = lobby_error(-1, "lobby info malformed"))
        Result.success as sp:
            return Result[LobbyInfo, Error].success(value = LobbyInfo(
                name = sp.value,
                player_count = player_count,
                max_players = max_players,
                player_names = vec.Vec[string.String].create(),
                game_data = bytes.Bytes.empty()
            ))


public async function respond_to_beacon(
    socket: net.UdpSocket,
    info: ref[LobbyInfo]
) -> void:
    var recv_task = socket.recv_from(1500)
    var frame: uint = 0
    while frame < beacon_recv_timeout:
        if aio.completed(recv_task):
            let recv_result = aio.result(recv_task)
            match recv_result:
                Result.success as dp:
                    var datagram = dp.value
                    defer datagram.data.release()
                    defer datagram.source.release()
                    if is_beacon_probe(datagram.data.as_span()):
                        var response = build_beacon_response(info)
                        defer response.release()
                        let _ = await socket.send_to(response.as_span(), datagram.source)
                Result.failure:
                    pass
        await aio.sleep(100)
        frame += 1
