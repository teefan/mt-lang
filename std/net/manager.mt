import std.async as aio
import std.bytes as bytes
import std.deque as deque
import std.net as net
import std.net.clock as clock
import std.net.mux as mux
import std.net.session as sess
import std.string as string
import std.vec as vec

const channel_system: ubyte = 0

const type_assign_id: ushort = 0xF000

const assign_id_bytes: ptr_uint = 4

public struct NetworkConfig:
    max_payload_bytes: ptr_uint
    max_players: ubyte

public enum NetworkEventKind: ubyte
    connected = 0
    disconnected = 1
    player_joined = 2
    player_left = 3
    message = 4

public struct NetworkEvent:
    kind: NetworkEventKind
    player_id: uint
    channel_id: ubyte
    type_id: ushort
    payload: bytes.Bytes

public struct NetworkManager:
    is_server: bool
    max_players: ubyte
    mux_session: mux.MuxedSession
    mux_connection: mux.MuxedConnection
    local_player_id: uint
    players: vec.Vec[PlayerState]
    next_player_id: uint
    events: deque.Deque[NetworkEvent]
    tick_clock: clock.TickClock
    connected: bool
    config: NetworkConfig
    stored_peer_id_events: deque.Deque[PlayerJoinEvent]

struct PlayerState:
    player_id: uint
    connected: bool

struct PlayerJoinEvent:
    player_id: uint


extending PlayerJoinEvent:
    public editable function release() -> void:
        pass


extending NetworkConfig:
    public static function default(max_payload_bytes: ptr_uint) -> NetworkConfig:
        return NetworkConfig(
            max_payload_bytes = max_payload_bytes,
            max_players = 8
        )


extending NetworkEvent:
    public editable function release() -> void:
        this.payload.release()


    public static function connected(player_id: uint) -> NetworkEvent:
        return NetworkEvent(
            kind = NetworkEventKind.connected,
            player_id = player_id,
            channel_id = 0ub,
            type_id = 0us,
            payload = bytes.Bytes.empty()
        )


    public static function disconnected() -> NetworkEvent:
        return NetworkEvent(
            kind = NetworkEventKind.disconnected,
            player_id = 0u,
            channel_id = 0ub,
            type_id = 0us,
            payload = bytes.Bytes.empty()
        )


    public static function player_joined(player_id: uint) -> NetworkEvent:
        return NetworkEvent(
            kind = NetworkEventKind.player_joined,
            player_id = player_id,
            channel_id = 0ub,
            type_id = 0us,
            payload = bytes.Bytes.empty()
        )


    public static function player_left(player_id: uint) -> NetworkEvent:
        return NetworkEvent(
            kind = NetworkEventKind.player_left,
            player_id = player_id,
            channel_id = 0ub,
            type_id = 0us,
            payload = bytes.Bytes.empty()
        )


    public static function message_event(
        player_id: uint,
        channel_id: ubyte,
        type_id: ushort,
        payload: bytes.Bytes
    ) -> NetworkEvent:
        return NetworkEvent(
            kind = NetworkEventKind.message,
            player_id = player_id,
            channel_id = channel_id,
            type_id = type_id,
            payload = payload
        )


function mux_config_for(config: NetworkConfig) -> mux.MuxedConfig:
    return mux.MuxedConfig(
        fragment_size = config.max_payload_bytes,
        fragment_timeout_frames = 120
    )


function build_assign_id(player_id: uint) -> bytes.Bytes:
    let encoded = encode_uint(player_id)
    return bytes.Bytes.copy(encoded.as_span())


function parse_assign_id(payload: span[ubyte]) -> Result[uint, net.Error]:
    if payload.len < assign_id_bytes:
        return Result[uint, net.Error].failure(error = net.net_error("assign id payload too short"))
    return Result[uint, net.Error].success(value = decode_uint(payload, 0))


function encode_uint(value: uint) -> array[ubyte, 4]:
    return array[ubyte, 4](
        ubyte<-((value >> 24) & 255),
        ubyte<-((value >> 16) & 255),
        ubyte<-((value >> 8) & 255),
        ubyte<-(value & 255)
    )


function decode_uint(data: span[ubyte], offset: ptr_uint) -> uint:
    return (
            ((uint<-data[offset]) << 24)
            | ((uint<-data[offset + 1]) << 16)
            | ((uint<-data[offset + 2]) << 8)
            | (uint<-data[offset + 3])
        )


extending NetworkManager:
    public editable function release() -> void:
        this.mux_session.release()
        this.mux_connection.release()

        while true:
            let ev = this.events.pop_front()
            match ev:
                Option.none:
                    break
                Option.some as p:
                    var e = p.value
                    e.release()

        this.events.release()

        while true:
            let je = this.stored_peer_id_events.pop_front()
            match je:
                Option.none:
                    break
                Option.some as p:
                    var j = p.value
                    j.release()

        this.stored_peer_id_events.release()

        this.players.release()


    public function is_server() -> bool:
        return this.is_server


    public function is_connected() -> bool:
        return this.connected


    public function local_player_id() -> uint:
        return this.local_player_id


    public function player_count() -> ptr_uint:
        return this.players.len()


    public function get_player(player_id: uint) -> Option[PlayerState]:
        var index: ptr_uint = 0
        while index < this.players.len():
            let player_ptr = this.players.get(index) else:
                return Option[PlayerState].none
            if unsafe: read(player_ptr).player_id == player_id:
                return Option[PlayerState].some(value = unsafe: read(player_ptr))
            index += 1
        return Option[PlayerState].none


    public function config() -> NetworkConfig:
        return this.config


    public async editable function tick(frame: uint) -> Result[bool, net.Error]:
        this.tick_clock.advance()

        if this.is_server:
            return await tick_server(ref_of(this), frame)
        return await tick_client(ref_of(this), frame)


    public editable function try_recv() -> Option[NetworkEvent]:
        return this.events.pop_front()


    public async editable function send_to_server(
        channel_id: ubyte,
        type_id: ushort,
        payload: span[ubyte],
        send_flags: ubyte
    ) -> Result[bool, net.Error]:
        if this.is_server:
            return Result[bool, net.Error].failure(
                error = net.net_error("send_to_server requires a client manager")
            )

        match await this.mux_connection.mux_send(channel_id, type_id, payload, send_flags):
            Result.failure as p:
                return Result[bool, net.Error].failure(error = p.error)
            Result.success:
                return Result[bool, net.Error].success(value = true)


    public async editable function send_to(
        player_id: uint,
        channel_id: ubyte,
        type_id: ushort,
        payload: span[ubyte],
        send_flags: ubyte
    ) -> Result[bool, net.Error]:
        if not this.is_server:
            return Result[bool, net.Error].failure(
                error = net.net_error("send_to requires a server manager")
            )

        match await this.mux_session.mux_send(player_id, channel_id, type_id, payload, send_flags):
            Result.failure as p:
                return Result[bool, net.Error].failure(error = p.error)
            Result.success:
                return Result[bool, net.Error].success(value = true)


    public async editable function broadcast(
        channel_id: ubyte,
        type_id: ushort,
        payload: span[ubyte],
        send_flags: ubyte
    ) -> Result[bool, net.Error]:
        if not this.is_server:
            return Result[bool, net.Error].failure(
                error = net.net_error("broadcast requires a server manager")
            )

        var index: ptr_uint = 0
        while index < this.players.len():
            let player_ptr = this.players.get(index) else:
                break

            if unsafe: read(player_ptr).connected:
                let peer_id = unsafe: read(player_ptr).player_id
                match await this.mux_session.mux_send(peer_id, channel_id, type_id, payload, send_flags):
                    Result.failure as p:
                        return Result[bool, net.Error].failure(error = p.error)
                    Result.success:
                        pass

            index += 1

        return Result[bool, net.Error].success(value = true)


    public async editable function rpc_server(rpc_id: ushort, data: span[ubyte]) -> Result[bool, net.Error]:
        return await this.send_to_server(channel_system, rpc_id, data, mux.flag_reliable)


    public async editable function rpc_to(
        player_id: uint,
        rpc_id: ushort,
        data: span[ubyte]
    ) -> Result[bool, net.Error]:
        return await this.send_to(player_id, channel_system, rpc_id, data, mux.flag_reliable)


    public async editable function rpc_all(rpc_id: ushort, data: span[ubyte]) -> Result[bool, net.Error]:
        return await this.broadcast(channel_system, rpc_id, data, mux.flag_reliable)


public function create_server(
    address: net.SocketAddress,
    config: NetworkConfig
) -> Result[NetworkManager, net.Error]:
    let mux_config = mux_config_for(config)
    match mux.mux_listen(address, mux_config):
        Result.failure as p:
            return Result[NetworkManager, net.Error].failure(error = p.error)
        Result.success as session_p:
            let mgr = NetworkManager(
                is_server = true,
                max_players = config.max_players,
                mux_session = session_p.value,
                mux_connection = unsafe: zero[mux.MuxedConnection],
                local_player_id = 0u,
                players = vec.Vec[PlayerState].create(),
                next_player_id = 1u,
                events = deque.Deque[NetworkEvent].create(),
                tick_clock = clock.TickClock(tick = 0u, rate = 60u, epoch = clock.monotonic_ns()),
                connected = true,
                config = config,
                stored_peer_id_events = deque.Deque[PlayerJoinEvent].create()
            )
            return Result[NetworkManager, net.Error].success(value = mgr)


public function create_client(
    local_address: net.SocketAddress,
    server_address: net.SocketAddress,
    config: NetworkConfig
) -> Result[NetworkManager, net.Error]:
    let mux_config = mux_config_for(config)
    match mux.mux_connect_on(aio.current_runtime(), local_address, server_address, mux_config):
        Result.failure as p:
            return Result[NetworkManager, net.Error].failure(error = p.error)
        Result.success as mux_conn_p:
            let client_mgr = NetworkManager(
                is_server = false,
                max_players = config.max_players,
                mux_session = unsafe: zero[mux.MuxedSession],
                mux_connection = mux_conn_p.value,
                local_player_id = 0u,
                players = vec.Vec[PlayerState].create(),
                next_player_id = 0u,
                events = deque.Deque[NetworkEvent].create(),
                tick_clock = clock.TickClock(tick = 0u, rate = 60u, epoch = clock.monotonic_ns()),
                connected = false,
                config = config,
                stored_peer_id_events = deque.Deque[PlayerJoinEvent].create()
            )
            return Result[NetworkManager, net.Error].success(value = client_mgr)


async function tick_server(manager: ref[NetworkManager], frame: uint) -> Result[bool, net.Error]:
    await process_stored_peer_id_events(manager)

    match await manager.mux_session.tick(frame):
        Result.failure as p:
            return Result[bool, net.Error].failure(error = p.error)
        Result.success:
            pass

    drain_mux_events_server(manager)

    return Result[bool, net.Error].success(value = true)


async function tick_client(manager: ref[NetworkManager], frame: uint) -> Result[bool, net.Error]:
    if manager.mux_connection.state() == sess.ConnectionState.disconnected:
        match await manager.mux_connection.connect_to_peer():
            Result.failure as p:
                return Result[bool, net.Error].failure(error = p.error)
            Result.success:
                pass

    match await manager.mux_connection.tick(frame):
        Result.failure as p:
            if manager.connected:
                manager.connected = false
                manager.events.push_back(NetworkEvent.disconnected())
            return Result[bool, net.Error].failure(error = p.error)
        Result.success:
            pass

    drain_mux_events_client(manager)

    return Result[bool, net.Error].success(value = true)


async function process_stored_peer_id_events(manager: ref[NetworkManager]) -> void:
    while true:
        let je = manager.stored_peer_id_events.pop_front()
        match je:
            Option.none:
                break
            Option.some as p:
                var join_event = p.value
                let player_id = join_event.player_id
                join_event.release()
                var assign_data = build_assign_id(player_id)
                defer assign_data.release()
                let _ = await manager.mux_session.mux_send(
                    player_id,
                    channel_system,
                    type_assign_id,
                    assign_data.as_span(),
                    mux.flag_reliable
                )


function drain_mux_events_server(manager: ref[NetworkManager]) -> void:
    while true:
        let ev = manager.mux_session.try_recv()
        match ev:
            Option.none:
                break
            Option.some as p:
                var msg = p.value
                handle_mux_message_server(manager, ref_of(msg))


function drain_mux_events_client(manager: ref[NetworkManager]) -> void:
    while true:
        let ev = manager.mux_connection.try_recv()
        match ev:
            Option.none:
                break
            Option.some as p:
                var msg = p.value
                handle_mux_message_client(manager, ref_of(msg))


function handle_mux_message_server(manager: ref[NetworkManager], msg: ref[mux.MuxedMessage]) -> void:
    if msg.channel_id == mux.meta_channel:
        if msg.type_id == mux.type_peer_joined:
            let peer_id = msg.peer_id
            msg.release()

            ensure_player_slot(manager, peer_id)
            manager.stored_peer_id_events.push_back(PlayerJoinEvent(player_id = peer_id))
            return

        if msg.type_id == mux.type_peer_left:
            let peer_id = msg.peer_id
            msg.release()

            mark_player_disconnected(manager, peer_id)
            manager.events.push_back(NetworkEvent.player_left(peer_id))
            return

        msg.release()
        return

    if msg.channel_id == channel_system and msg.type_id == type_assign_id:
        msg.release()
        return

    manager.events.push_back(NetworkEvent.message_event(
        msg.peer_id,
        msg.channel_id,
        msg.type_id,
        msg.payload
    ))

    unsafe:
        read(ptr[mux.MuxedMessage]<-msg).payload = bytes.Bytes.empty()


function handle_mux_message_client(manager: ref[NetworkManager], msg: ref[mux.MuxedMessage]) -> void:
    if msg.channel_id == mux.meta_channel:
        msg.release()
        return

    if msg.channel_id == channel_system and msg.type_id == type_assign_id:
        let id_result = parse_assign_id(msg.payload.as_span())
        match id_result:
            Result.success as p:
                manager.local_player_id = p.value
                manager.connected = true
                manager.events.push_back(NetworkEvent.connected(p.value))
            Result.failure:
                pass
        msg.release()
        return

    manager.events.push_back(NetworkEvent.message_event(
        msg.peer_id,
        msg.channel_id,
        msg.type_id,
        msg.payload
    ))

    unsafe:
        read(ptr[mux.MuxedMessage]<-msg).payload = bytes.Bytes.empty()


function ensure_player_slot(manager: ref[NetworkManager], player_id: uint) -> void:
    var index: ptr_uint = 0
    while index < manager.players.len():
        let player_ptr = manager.players.get(index) else:
            break
        if unsafe: read(player_ptr).player_id == player_id:
            unsafe: read(player_ptr).connected = true
            return
        index += 1

    manager.players.push(PlayerState(player_id = player_id, connected = true))
    manager.events.push_back(NetworkEvent.player_joined(player_id))


function mark_player_disconnected(manager: ref[NetworkManager], player_id: uint) -> void:
    var index: ptr_uint = 0
    while index < manager.players.len():
        let player_ptr = manager.players.get(index) else:
            break
        if unsafe: read(player_ptr).player_id == player_id:
            unsafe: read(player_ptr).connected = false
            return
        index += 1
