import std.libjuice as juice
import std.bytes as bytes
import std.mem.heap as heap
import std.multiplayer as mp
import std.multiplayer.protocol as protocol
import std.multiplayer.rpc as rpc_runtime
import std.multiplayer.signal as signal
import std.multiplayer.snapshot as snapshot_runtime
import std.multiplayer.wire as wire
import std.str as text
import std.string as string
import std.vec as vec

public type TypedRpcRoute = rpc_runtime.TypedRpcRoute
public type TypedRpcDispatchTable = rpc_runtime.TypedRpcDispatchTable

public enum ConnectionState: ubyte
    idle = 0
    gathering = 1
    awaiting_remote = 2
    connecting = 3
    connected = 4
    failed = 5
    closed = 6

public enum SessionEvent: ubyte
    connected = 0
    disconnected = 1
    state_changed = 2
    error = 3

public struct SessionEventRecord:
    kind: SessionEvent
    message: string.String

public type ConnectionIdentityProvider = fn(is_server: bool, session_id: str) -> Option[mp.ConnectionId]

public struct SenderRoute:
    channel: uint
    connection: mp.ConnectionId

public struct IceConfig:
    stun_server_host: cstr
    stun_server_port: ushort
    bind_address: cstr
    local_port_range_begin: ushort
    local_port_range_end: ushort
    trickle_candidates: bool
    concurrency_mode: juice.ConcurrencyMode
    identity_provider: ConnectionIdentityProvider

public struct Server:
    agent: juice.Agent?
    world: mp.World
    protocol_hash_value: ulong
    session_id: string.String
    protocol_verified: bool
    verified_connection: Option[mp.ConnectionId]
    connection_state: ConnectionState
    session_events: vec.Vec[SessionEventRecord]
    receive_context: ptr[IceReceiveContext]?
    ice: IceConfig

public struct Client:
    agent: juice.Agent?
    world: mp.World
    protocol_hash_value: ulong
    session_id: string.String
    protocol_verified: bool
    connection_id_value: Option[mp.ConnectionId]
    connection_state: ConnectionState
    session_events: vec.Vec[SessionEventRecord]
    receive_context: ptr[IceReceiveContext]?
    ice: IceConfig


public function default_ice_config() -> IceConfig:
    return IceConfig(
        stun_server_host = c"",
        stun_server_port = 3478,
        bind_address = c"",
        local_port_range_begin = 0,
        local_port_range_end = 0,
        trickle_candidates = true,
        concurrency_mode = juice.ConcurrencyMode.JUICE_CONCURRENCY_MODE_THREAD,
        identity_provider = default_connection_identity
    )


public function listen(
    registry: mp.Registry,
    config: mp.Config,
    ice: IceConfig,
) -> Result[Server, mp.Error]:
    let world = mp.World.create(registry, config, mp.WorldRole.server) else as world_error:
        return Result[Server, mp.Error].failure(error = world_error)

    let receive_context = create_receive_context(
        mp.RpcDirection.client_to_server,
        Option[mp.ConnectionId].none
    )

    let agent = create_agent(ice, unsafe: ptr[void]<-receive_context) else as agent_error:
        release_receive_context(receive_context)
        var failed_world = world
        failed_world.release()
        return Result[Server, mp.Error].failure(error = agent_error)

    return Result[Server, mp.Error].success(value = Server(
        agent = agent,
        world = world,
        protocol_hash_value = registry.protocol_hash(),
        session_id = string.String.create(),
        protocol_verified = false,
        verified_connection = Option[mp.ConnectionId].none,
        connection_state = ConnectionState.gathering,
        session_events = vec.Vec[SessionEventRecord].create(),
        receive_context = receive_context,
        ice = ice
    ))


public function connect(
    registry: mp.Registry,
    config: mp.Config,
    ice: IceConfig,
) -> Result[Client, mp.Error]:
    let world = mp.World.create(registry, config, mp.WorldRole.client) else as world_error:
        return Result[Client, mp.Error].failure(error = world_error)

    let receive_context = create_receive_context(
        mp.RpcDirection.server_to_connection,
        Option[mp.ConnectionId].none
    )

    let agent = create_agent(ice, unsafe: ptr[void]<-receive_context) else as agent_error:
        release_receive_context(receive_context)
        var failed_world = world
        failed_world.release()
        return Result[Client, mp.Error].failure(error = agent_error)

    return Result[Client, mp.Error].success(value = Client(
        agent = agent,
        world = world,
        protocol_hash_value = registry.protocol_hash(),
        session_id = string.String.create(),
        protocol_verified = false,
        connection_id_value = Option[mp.ConnectionId].none,
        connection_state = ConnectionState.gathering,
        session_events = vec.Vec[SessionEventRecord].create(),
        receive_context = receive_context,
        ice = ice
    ))


extending Server:
    public mutable function world_ptr() -> ptr[mp.World]:
        return ptr_of(this.world)


    public mutable function pump(timeout_ms: uint) -> Result[ptr_uint, mp.Error]:
        return refresh_server_state(ref_of(this))


    public function protocol_ready() -> bool:
        return this.protocol_verified and this.connection_state == ConnectionState.connected


    public function has_verified_connection(connection: mp.ConnectionId) -> bool:
        match this.verified_connection:
            Option.some as value:
                return value.value == connection and this.protocol_ready()
            Option.none:
                return false


    public function first_verified_connection() -> Option[mp.ConnectionId]:
        if not this.protocol_ready():
            return Option[mp.ConnectionId].none

        return this.verified_connection


    public mutable function create_answer(offer: signal.Offer) -> Result[signal.Answer, mp.Error]:
        let _ = signal.validate_offer(offer, this.protocol_hash_value) else as signal_error:
            return Result[signal.Answer, mp.Error].failure(error = signal_error)

        let agent = this.agent else:
            return Result[signal.Answer, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "ice server agent is not initialized"
            ))

        let apply_status = juice.set_remote_description(agent, offer.description())
        if not juice_status_ok(apply_status):
            return Result[signal.Answer, mp.Error].failure(error = mp.error(
                mp.ErrorCode.unsupported,
                "libjuice rejected remote offer description"
            ))

        this.session_id.assign(offer.session())
        this.protocol_verified = true
        this.verified_connection = resolve_connection_identity(
            this.ice.identity_provider,
            true,
            this.session_id.as_str()
        )

        if this.verified_connection == Option[mp.ConnectionId].none:
            return Result[signal.Answer, mp.Error].failure(error = mp.error(
                mp.ErrorCode.invalid_argument,
                "ice server identity_provider returned no verified connection id"
            ))

        if this.receive_context != null:
            let context = this.receive_context else:
                fatal(c"ice server receive context unexpectedly missing during answer creation")
            set_default_sender(unsafe: ref_of(read(context)), this.verified_connection)

        var local_sdp = local_description(agent) else as description_error:
            return Result[signal.Answer, mp.Error].failure(error = description_error)

        this.connection_state = map_state(juice.get_state(agent))
        let reply = signal.answer(
            this.session_id.as_str(),
            this.protocol_hash_value,
            local_sdp.as_str(),
            this.ice.trickle_candidates
        )
        local_sdp.release()
        return Result[signal.Answer, mp.Error].success(value = reply)


    public function add_remote_candidate(candidate: signal.Candidate) -> Result[bool, mp.Error]:
        let _ = signal.validate_candidate(candidate) else as validation_error:
            return Result[bool, mp.Error].failure(error = validation_error)

        if not candidate.session().equal(this.session_id.as_str()):
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.invalid_argument,
                "signal candidate session_id does not match active ice server session"
            ))

        let agent = this.agent else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "ice server agent is not initialized"
            ))

        let status = juice.add_remote_candidate(agent, candidate.value())
        if not juice_status_ok(status):
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.unsupported,
                "libjuice rejected remote candidate"
            ))

        return Result[bool, mp.Error].success(value = true)


    public function mark_remote_gathering_done() -> Result[bool, mp.Error]:
        let agent = this.agent else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "ice server agent is not initialized"
            ))

        let status = juice.set_remote_gathering_done(agent)
        if not juice_status_ok(status):
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.unsupported,
                "libjuice failed to mark remote gathering done"
            ))

        return Result[bool, mp.Error].success(value = true)


    public mutable function pop_session_event() -> Option[SessionEventRecord]:
        return dequeue_session_event(ref_of(this.session_events))


    public function pending_session_event_count() -> ptr_uint:
        return this.session_events.len()


    public function pending_snapshot_count() -> ptr_uint:
        let context = this.receive_context else:
            return 0
        return unsafe: read(context).incoming_snapshots.len()


    public mutable function pop_snapshot() -> Option[snapshot_runtime.IncomingSnapshotPacket]:
        let context = this.receive_context else:
            return Option[snapshot_runtime.IncomingSnapshotPacket].none
        return snapshot_runtime.dequeue_incoming(unsafe: ref_of(read(context).incoming_snapshots))


    public function pending_rpc_count() -> ptr_uint:
        let context = this.receive_context else:
            return 0
        return unsafe: read(context).incoming_rpcs.len()


    public mutable function pop_rpc() -> Option[rpc_runtime.IncomingRpcPacket]:
        let context = this.receive_context else:
            return Option[rpc_runtime.IncomingRpcPacket].none
        return rpc_runtime.dequeue_incoming(unsafe: ref_of(read(context).incoming_rpcs))


    public function pending_unknown_count() -> ptr_uint:
        let context = this.receive_context else:
            return 0
        return unsafe: read(context).unknown_packet_count


    public function snapshot_baseline_state() -> snapshot_runtime.BaselineSet:
        let context = this.receive_context else:
            return empty_ice_baseline()
        return unsafe: read(context).inbound_snapshot_baseline


    public mutable function map_inbound_channel_sender(
        channel: uint,
        connection: mp.ConnectionId
    ) -> Result[bool, mp.Error]:
        let context = this.receive_context else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "ice server receive context is not initialized"
            ))

        return set_sender_route(unsafe: ref_of(read(context)), channel, connection)


    public mutable function process_incoming_snapshots() -> Result[ptr_uint, mp.Error]:
        let context = this.receive_context else:
            return Result[ptr_uint, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "ice server receive context is not initialized"
            ))

        return this.world.drain_incoming_snapshots(
            unsafe: ref_of(read(context).incoming_snapshots),
            unsafe: ref_of(read(context).inbound_snapshot_baseline)
        )


    public mutable function process_incoming_rpcs_typed(
        table: ref[rpc_runtime.TypedRpcDispatchTable],
    ) -> Result[ptr_uint, mp.Error]:
        let context = this.receive_context else:
            return Result[ptr_uint, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "ice server receive context is not initialized"
            ))

        return rpc_runtime.drain_incoming_typed_packets(unsafe: ref_of(read(context).incoming_rpcs), table)


    public mutable function broadcast_snapshot(
        channel: uint,
        transfer_mode: mp.TransferMode,
        header: mp.SnapshotPacketHeader,
        payload: span[ubyte],
    ) -> Result[bool, mp.Error]:
        let agent = this.agent else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "ice server agent is not initialized"
            ))

        var encoded = snapshot_runtime.build_payload(header, payload)
        defer encoded.release()
        return send_snapshot_wire_payload(agent, channel, encoded.as_span())


    public mutable function broadcast_rpc(
        channel: uint,
        transfer_mode: mp.TransferMode,
        direction: mp.RpcDirection,
        payload: span[ubyte],
    ) -> Result[bool, mp.Error]:
        let _ = rpc_runtime.validate_server_outbound_direction(direction) else as direction_error:
            return Result[bool, mp.Error].failure(error = direction_error)

        let agent = this.agent else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "ice server agent is not initialized"
            ))

        let header = mp.RpcPacketHeader(channel = channel, direction = direction, payload_size = payload.len)
        var encoded = rpc_runtime.build_payload(header, payload)
        defer encoded.release()
        return send_wire_payload(agent, mp.PacketKind.rpc, encoded.as_span())


    public mutable function release() -> void:
        if this.agent != null:
            let agent = this.agent else:
                fatal(c"ice server agent unexpectedly missing during release")
            juice.destroy(agent)
            this.agent = null

        if this.receive_context != null:
            let context = this.receive_context else:
                fatal(c"ice server receive context unexpectedly missing during release")
            release_receive_context(context)
            this.receive_context = null

        release_session_events(ref_of(this.session_events))
        this.session_id.release()
        this.world.release()
        this.protocol_verified = false
        this.verified_connection = Option[mp.ConnectionId].none
        this.connection_state = ConnectionState.closed


extending Client:
    public mutable function world_ptr() -> ptr[mp.World]:
        return ptr_of(this.world)


    public mutable function pump(timeout_ms: uint) -> Result[ptr_uint, mp.Error]:
        return refresh_client_state(ref_of(this))


    public function protocol_ready() -> bool:
        return this.protocol_verified and this.connection_state == ConnectionState.connected


    public function connection_id() -> Option[mp.ConnectionId]:
        if not this.protocol_ready():
            return Option[mp.ConnectionId].none

        return this.connection_id_value


    public mutable function create_offer(session_id: str) -> Result[signal.Offer, mp.Error]:
        if session_id.len == 0:
            return Result[signal.Offer, mp.Error].failure(error = mp.error(
                mp.ErrorCode.invalid_argument,
                "signal session_id must not be empty"
            ))

        let agent = this.agent else:
            return Result[signal.Offer, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "ice client agent is not initialized"
            ))

        this.session_id.assign(session_id)
        this.connection_state = ConnectionState.awaiting_remote

        var local_sdp = local_description(agent) else as description_error:
            return Result[signal.Offer, mp.Error].failure(error = description_error)

        let payload = signal.offer(
            this.session_id.as_str(),
            this.protocol_hash_value,
            local_sdp.as_str(),
            this.ice.trickle_candidates
        )
        local_sdp.release()
        return Result[signal.Offer, mp.Error].success(value = payload)


    public mutable function apply_answer(answer: signal.Answer) -> Result[bool, mp.Error]:
        let _ = signal.validate_answer(answer, this.protocol_hash_value) else as validation_error:
            return Result[bool, mp.Error].failure(error = validation_error)

        if not answer.session().equal(this.session_id.as_str()):
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.invalid_argument,
                "signal answer session_id does not match active ice client session"
            ))

        let agent = this.agent else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "ice client agent is not initialized"
            ))

        let apply_status = juice.set_remote_description(agent, answer.description())
        if not juice_status_ok(apply_status):
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.unsupported,
                "libjuice rejected remote answer description"
            ))

        this.protocol_verified = true
        this.connection_id_value = resolve_connection_identity(
            this.ice.identity_provider,
            false,
            this.session_id.as_str()
        )

        if this.connection_id_value == Option[mp.ConnectionId].none:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.invalid_argument,
                "ice client identity_provider returned no local connection id"
            ))

        if this.receive_context != null:
            let context = this.receive_context else:
                fatal(c"ice client receive context unexpectedly missing during answer apply")
            set_default_sender(unsafe: ref_of(read(context)), this.connection_id_value)

        this.connection_state = map_state(juice.get_state(agent))
        return Result[bool, mp.Error].success(value = true)


    public function add_remote_candidate(candidate: signal.Candidate) -> Result[bool, mp.Error]:
        let _ = signal.validate_candidate(candidate) else as validation_error:
            return Result[bool, mp.Error].failure(error = validation_error)

        if not candidate.session().equal(this.session_id.as_str()):
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.invalid_argument,
                "signal candidate session_id does not match active ice client session"
            ))

        let agent = this.agent else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "ice client agent is not initialized"
            ))

        let status = juice.add_remote_candidate(agent, candidate.value())
        if not juice_status_ok(status):
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.unsupported,
                "libjuice rejected remote candidate"
            ))

        return Result[bool, mp.Error].success(value = true)


    public function mark_remote_gathering_done() -> Result[bool, mp.Error]:
        let agent = this.agent else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "ice client agent is not initialized"
            ))

        let status = juice.set_remote_gathering_done(agent)
        if not juice_status_ok(status):
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.unsupported,
                "libjuice failed to mark remote gathering done"
            ))

        return Result[bool, mp.Error].success(value = true)


    public function send_snapshot(
        channel: uint,
        transfer_mode: mp.TransferMode,
        header: mp.SnapshotPacketHeader,
        payload: span[ubyte],
    ) -> Result[bool, mp.Error]:
        if not this.protocol_ready():
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.unsupported,
                "protocol handshake is not complete"
            ))

        let agent = this.agent else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "ice client agent is not initialized"
            ))

        var encoded = snapshot_runtime.build_payload(header, payload)
        defer encoded.release()
        return send_snapshot_wire_payload(agent, channel, encoded.as_span())


    public function send_rpc(
        channel: uint,
        transfer_mode: mp.TransferMode,
        direction: mp.RpcDirection,
        payload: span[ubyte],
    ) -> Result[bool, mp.Error]:
        let _ = rpc_runtime.validate_client_outbound_direction(direction) else as direction_error:
            return Result[bool, mp.Error].failure(error = direction_error)

        let agent = this.agent else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "ice client agent is not initialized"
            ))

        let header = mp.RpcPacketHeader(channel = channel, direction = direction, payload_size = payload.len)
        var encoded = rpc_runtime.build_payload(header, payload)
        defer encoded.release()
        return send_wire_payload(agent, mp.PacketKind.rpc, encoded.as_span())


    public mutable function pop_session_event() -> Option[SessionEventRecord]:
        return dequeue_session_event(ref_of(this.session_events))


    public function pending_session_event_count() -> ptr_uint:
        return this.session_events.len()


    public function pending_snapshot_count() -> ptr_uint:
        let context = this.receive_context else:
            return 0
        return unsafe: read(context).incoming_snapshots.len()


    public mutable function pop_snapshot() -> Option[snapshot_runtime.IncomingSnapshotPacket]:
        let context = this.receive_context else:
            return Option[snapshot_runtime.IncomingSnapshotPacket].none
        return snapshot_runtime.dequeue_incoming(unsafe: ref_of(read(context).incoming_snapshots))


    public function pending_rpc_count() -> ptr_uint:
        let context = this.receive_context else:
            return 0
        return unsafe: read(context).incoming_rpcs.len()


    public mutable function pop_rpc() -> Option[rpc_runtime.IncomingRpcPacket]:
        let context = this.receive_context else:
            return Option[rpc_runtime.IncomingRpcPacket].none
        return rpc_runtime.dequeue_incoming(unsafe: ref_of(read(context).incoming_rpcs))


    public function pending_unknown_count() -> ptr_uint:
        let context = this.receive_context else:
            return 0
        return unsafe: read(context).unknown_packet_count


    public function snapshot_baseline_state() -> snapshot_runtime.BaselineSet:
        let context = this.receive_context else:
            return empty_ice_baseline()
        return unsafe: read(context).inbound_snapshot_baseline


    public mutable function map_inbound_channel_sender(
        channel: uint,
        connection: mp.ConnectionId
    ) -> Result[bool, mp.Error]:
        let context = this.receive_context else:
            return Result[bool, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "ice client receive context is not initialized"
            ))

        return set_sender_route(unsafe: ref_of(read(context)), channel, connection)


    public mutable function process_incoming_snapshots() -> Result[ptr_uint, mp.Error]:
        let context = this.receive_context else:
            return Result[ptr_uint, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "ice client receive context is not initialized"
            ))

        return this.world.drain_incoming_snapshots(
            unsafe: ref_of(read(context).incoming_snapshots),
            unsafe: ref_of(read(context).inbound_snapshot_baseline)
        )


    public mutable function process_incoming_rpcs_typed(
        table: ref[rpc_runtime.TypedRpcDispatchTable],
    ) -> Result[ptr_uint, mp.Error]:
        let context = this.receive_context else:
            return Result[ptr_uint, mp.Error].failure(error = mp.error(
                mp.ErrorCode.not_found,
                "ice client receive context is not initialized"
            ))

        return rpc_runtime.drain_incoming_typed_packets(unsafe: ref_of(read(context).incoming_rpcs), table)


    public mutable function release() -> void:
        if this.agent != null:
            let agent = this.agent else:
                fatal(c"ice client agent unexpectedly missing during release")
            juice.destroy(agent)
            this.agent = null

        if this.receive_context != null:
            let context = this.receive_context else:
                fatal(c"ice client receive context unexpectedly missing during release")
            release_receive_context(context)
            this.receive_context = null

        release_session_events(ref_of(this.session_events))
        this.session_id.release()
        this.world.release()
        this.protocol_verified = false
        this.connection_id_value = Option[mp.ConnectionId].none
        this.connection_state = ConnectionState.closed


function create_agent(ice: IceConfig, user_ptr: ptr[void]) -> Result[juice.Agent, mp.Error]:
    var config = zero[juice.Config]
    config.concurrency_mode = ice.concurrency_mode
    config.stun_server_host = ice.stun_server_host
    config.stun_server_port = ice.stun_server_port
    config.turn_servers = zero[ptr[juice.TurnServer]]
    config.turn_servers_count = 0
    config.bind_address = ice.bind_address
    config.local_port_range_begin = ice.local_port_range_begin
    config.local_port_range_end = ice.local_port_range_end
    config.cb_state_changed = noop_state_changed
    config.cb_candidate = noop_candidate
    config.cb_gathering_done = noop_gathering_done
    config.cb_recv = ice_recv_callback
    config.user_ptr = user_ptr

    let agent = juice.create(ptr_of(config)) else:
        return Result[juice.Agent, mp.Error].failure(error = mp.error(
            mp.ErrorCode.unsupported,
            "libjuice agent creation failed"
        ))

    let gather_status = juice.gather_candidates(agent)
    if not juice_status_ok(gather_status):
        juice.destroy(agent)
        return Result[juice.Agent, mp.Error].failure(error = mp.error(
            mp.ErrorCode.unsupported,
            "libjuice candidate gathering failed"
        ))

    return Result[juice.Agent, mp.Error].success(value = agent)


function local_description(agent: juice.Agent) -> Result[string.String, mp.Error]:
    let buffer_size = ptr_uint<-juice.MAX_SDP_STRING_LEN
    let buffer = heap.must_alloc[char](buffer_size)
    defer heap.release(buffer)

    let status = juice.get_local_description(agent, buffer, buffer_size)
    if not juice_status_ok(status):
        return Result[string.String, mp.Error].failure(error = mp.error(
            mp.ErrorCode.unsupported,
            "libjuice failed to read local description"
        ))

    let description = text.chars_as_str(buffer)
    if description.len == 0:
        return Result[string.String, mp.Error].failure(error = mp.error(
            mp.ErrorCode.unsupported,
            "libjuice returned an empty local description"
        ))

    return Result[string.String, mp.Error].success(value = string.String.from_str(description))


function map_state(value: juice.State) -> ConnectionState:
    match value:
        juice.State.JUICE_STATE_DISCONNECTED:
            return ConnectionState.idle
        juice.State.JUICE_STATE_GATHERING:
            return ConnectionState.gathering
        juice.State.JUICE_STATE_CONNECTING:
            return ConnectionState.connecting
        juice.State.JUICE_STATE_CONNECTED:
            return ConnectionState.connected
        juice.State.JUICE_STATE_COMPLETED:
            return ConnectionState.connected
        juice.State.JUICE_STATE_FAILED:
            return ConnectionState.failed


function juice_status_ok(code: int) -> bool:
    return code == juice.ERR_SUCCESS or code == juice.ERR_IGNORED


function refresh_server_state(server: ref[Server]) -> Result[ptr_uint, mp.Error]:
    let agent = read(server).agent else:
        return Result[ptr_uint, mp.Error].failure(error = mp.error(
            mp.ErrorCode.not_found,
            "ice server agent is not initialized"
        ))

    let previous = read(server).connection_state
    let current = map_state(juice.get_state(agent))
    read(server).connection_state = current

    if previous != current:
        enqueue_state_event(ref_of(read(server).session_events), current)
        if current == ConnectionState.connected:
            enqueue_static_event(ref_of(read(server).session_events), SessionEvent.connected, "ice server connected")
        if current == ConnectionState.failed:
            enqueue_static_event(
                ref_of(read(server).session_events),
                SessionEvent.error,
                "ice server connection failed"
            )
        return Result[ptr_uint, mp.Error].success(value = 1)

    return Result[ptr_uint, mp.Error].success(value = 0)


function refresh_client_state(client: ref[Client]) -> Result[ptr_uint, mp.Error]:
    let agent = read(client).agent else:
        return Result[ptr_uint, mp.Error].failure(error = mp.error(
            mp.ErrorCode.not_found,
            "ice client agent is not initialized"
        ))

    let previous = read(client).connection_state
    let current = map_state(juice.get_state(agent))
    read(client).connection_state = current

    if previous != current:
        enqueue_state_event(ref_of(read(client).session_events), current)
        if current == ConnectionState.connected:
            enqueue_static_event(ref_of(read(client).session_events), SessionEvent.connected, "ice client connected")
        if current == ConnectionState.failed:
            enqueue_static_event(
                ref_of(read(client).session_events),
                SessionEvent.error,
                "ice client connection failed"
            )
        return Result[ptr_uint, mp.Error].success(value = 1)

    return Result[ptr_uint, mp.Error].success(value = 0)


function enqueue_state_event(queue: ref[vec.Vec[SessionEventRecord]], state: ConnectionState) -> void:
    match state:
        ConnectionState.idle:
            enqueue_static_event(queue, SessionEvent.state_changed, "ice state: idle")
        ConnectionState.gathering:
            enqueue_static_event(queue, SessionEvent.state_changed, "ice state: gathering")
        ConnectionState.awaiting_remote:
            enqueue_static_event(queue, SessionEvent.state_changed, "ice state: awaiting_remote")
        ConnectionState.connecting:
            enqueue_static_event(queue, SessionEvent.state_changed, "ice state: connecting")
        ConnectionState.connected:
            enqueue_static_event(queue, SessionEvent.state_changed, "ice state: connected")
        ConnectionState.failed:
            enqueue_static_event(queue, SessionEvent.state_changed, "ice state: failed")
        ConnectionState.closed:
            enqueue_static_event(queue, SessionEvent.state_changed, "ice state: closed")


function enqueue_static_event(queue: ref[vec.Vec[SessionEventRecord]], kind: SessionEvent, message: str) -> void:
    queue.push(SessionEventRecord(kind = kind, message = string.String.from_str(message)))


function dequeue_session_event(queue: ref[vec.Vec[SessionEventRecord]]) -> Option[SessionEventRecord]:
    if queue.len() == 0:
        return Option[SessionEventRecord].none

    match queue.remove(0):
        Option.some as value:
            return Option[SessionEventRecord].some(value = value.value)
        Option.none:
            return Option[SessionEventRecord].none


function release_session_events(queue: ref[vec.Vec[SessionEventRecord]]) -> void:
    while true:
        match queue.pop():
            Option.some as payload:
                var value = payload.value
                value.message.release()
            Option.none:
                queue.release()
                return


function send_wire_payload(agent: juice.Agent, kind: mp.PacketKind, payload: span[ubyte]) -> Result[bool, mp.Error]:
    var framed = prepend_packet_kind(kind, payload)
    defer framed.release()

    let status = unsafe: juice.send(
        agent,
        str(data = ptr[char]<-framed.data, len = framed.len),
        framed.len
    )
    if status < 0:
        return Result[bool, mp.Error].failure(error = mp.error(
            mp.ErrorCode.unsupported,
            "libjuice send failed"
        ))

    return Result[bool, mp.Error].success(value = true)


function send_snapshot_wire_payload(agent: juice.Agent, channel: uint, payload: span[ubyte]) -> Result[bool, mp.Error]:
    var framed = prepend_packet_kind_and_channel(mp.PacketKind.snapshot, channel, payload)
    defer framed.release()

    let status = unsafe: juice.send(
        agent,
        str(data = ptr[char]<-framed.data, len = framed.len),
        framed.len
    )
    if status < 0:
        return Result[bool, mp.Error].failure(error = mp.error(
            mp.ErrorCode.unsupported,
            "libjuice send failed"
        ))

    return Result[bool, mp.Error].success(value = true)


function prepend_packet_kind(kind: mp.PacketKind, payload: span[ubyte]) -> bytes.Bytes:
    var framed = vec.Vec[ubyte].with_capacity(payload.len + 1)
    defer framed.release()
    framed.push(ubyte<-kind)
    framed.append_span(payload)

    return bytes.Bytes.copy(framed.as_span())


function prepend_packet_kind_and_channel(kind: mp.PacketKind, channel: uint, payload: span[ubyte]) -> bytes.Bytes:
    var framed = vec.Vec[ubyte].with_capacity(payload.len + 5)
    defer framed.release()
    framed.push(ubyte<-kind)
    framed.append_array(wire.encode_u32_be(channel))
    framed.append_span(payload)

    return bytes.Bytes.copy(framed.as_span())


function handle_received_payload(
    context: ref[IceReceiveContext],
    payload: span[ubyte],
) -> void:
    let inferred_direction = read(context).inferred_direction

    if payload.len < 1:
        rpc_runtime.increment_unknown_count(ref_of(read(context).unknown_packet_count))
        return

    let kind = protocol.packet_kind_from_byte(payload[0]) else:
        rpc_runtime.increment_unknown_count(ref_of(read(context).unknown_packet_count))
        return

    unsafe:
        let body = span[ubyte](data = payload.data + 1, len = payload.len - 1)
        match kind:
            mp.PacketKind.snapshot:
                if body.len < 4:
                    rpc_runtime.increment_unknown_count(ref_of(read(context).unknown_packet_count))
                    return

                let channel = wire.decode_u32_be(body, 0)
                let snapshot_payload = span[ubyte](data = body.data + 4, len = body.len - 4)
                match snapshot_runtime.enqueue_incoming(
                    ref_of(read(context).incoming_snapshots),
                    read(context).default_sender,
                    channel,
                    snapshot_payload
                ):
                    Result.success:
                        pass
                    Result.failure:
                        rpc_runtime.increment_unknown_count(ref_of(read(context).unknown_packet_count))
            mp.PacketKind.rpc:
                let rpc_direction = rpc_runtime.infer_inbound_rpc_direction(body, inferred_direction) else:
                    rpc_runtime.increment_unknown_count(ref_of(read(context).unknown_packet_count))
                    return

                let header = rpc_runtime.decode_header(body) else:
                    rpc_runtime.increment_unknown_count(ref_of(read(context).unknown_packet_count))
                    return

                let sender = resolve_sender_for_channel(ref_of(read(context)), header.channel)

                match rpc_runtime.enqueue_incoming(
                    ref_of(read(context).incoming_rpcs),
                    sender,
                    header.channel,
                    rpc_direction,
                    body
                ):
                    Result.success:
                        pass
                    Result.failure:
                        rpc_runtime.increment_unknown_count(ref_of(read(context).unknown_packet_count))
            mp.PacketKind.handshake_hello:
                rpc_runtime.increment_unknown_count(ref_of(read(context).unknown_packet_count))
            mp.PacketKind.handshake_welcome:
                rpc_runtime.increment_unknown_count(ref_of(read(context).unknown_packet_count))
            mp.PacketKind.handshake_reject:
                rpc_runtime.increment_unknown_count(ref_of(read(context).unknown_packet_count))


function ice_recv_callback(agent: juice.Agent, data: cstr, size: ptr_uint, user_ptr: ptr[void]) -> void:
    if data == c"":
        pass

    if user_ptr == zero[ptr[void]]:
        return

    unsafe:
        let receiver = ptr[IceReceiveContext]<-user_ptr
        let incoming = span[ubyte](data = ptr[ubyte]<-ptr[char]<-data, len = size)
        handle_received_payload(ref_of(read(receiver)), incoming)


public struct IceReceiveContext:
    incoming_snapshots: vec.Vec[snapshot_runtime.IncomingSnapshotPacket]
    incoming_rpcs: vec.Vec[rpc_runtime.IncomingRpcPacket]
    unknown_packet_count: ptr_uint
    inbound_snapshot_baseline: snapshot_runtime.BaselineSet
    inferred_direction: mp.RpcDirection
    default_sender: Option[mp.ConnectionId]
    sender_routes: vec.Vec[SenderRoute]


function create_receive_context(
    inferred_direction: mp.RpcDirection,
    default_sender: Option[mp.ConnectionId],
) -> ptr[IceReceiveContext]:
    let context = heap.must_alloc[IceReceiveContext](1)
    unsafe:
        read(context) = IceReceiveContext(
            incoming_snapshots = vec.Vec[snapshot_runtime.IncomingSnapshotPacket].create(),
            incoming_rpcs = vec.Vec[rpc_runtime.IncomingRpcPacket].create(),
            unknown_packet_count = 0,
            inbound_snapshot_baseline = snapshot_runtime.BaselineSet(
                last_applied_tick = 0,
                last_applied_entity_count = 0,
                last_applied_payload_bytes = 0,
                last_applied_payload_hash = 0
            ),
            inferred_direction = inferred_direction,
            default_sender = default_sender,
            sender_routes = vec.Vec[SenderRoute].create()
        )
    return context


function release_receive_context(context: ptr[IceReceiveContext]) -> void:
    unsafe:
        snapshot_runtime.release_queue(ref_of(read(context).incoming_snapshots))
        rpc_runtime.release_queue(ref_of(read(context).incoming_rpcs))
        read(context).sender_routes.release()
    heap.release(context)


function resolve_sender_for_channel(
    context: ref[IceReceiveContext],
    channel: uint,
) -> Option[mp.ConnectionId]:
    var index: ptr_uint = 0
    while index < read(context).sender_routes.len():
        let route_ptr = read(context).sender_routes.get(index)
        if route_ptr == null:
            break
        unsafe:
            if read(ptr[SenderRoute]<-route_ptr).channel == channel:
                return Option[mp.ConnectionId].some(value = read(ptr[SenderRoute]<-route_ptr).connection)
        index += 1

    return read(context).default_sender


function set_sender_route(
    context: ref[IceReceiveContext],
    channel: uint,
    connection: mp.ConnectionId,
) -> Result[bool, mp.Error]:
    var index: ptr_uint = 0
    while index < read(context).sender_routes.len():
        let route_ptr = read(context).sender_routes.get(index)
        if route_ptr == null:
            break
        unsafe:
            if read(ptr[SenderRoute]<-route_ptr).channel == channel:
                read(ptr[SenderRoute]<-route_ptr).connection = connection
                return Result[bool, mp.Error].success(value = true)
        index += 1

    read(context).sender_routes.push(SenderRoute(channel = channel, connection = connection))
    return Result[bool, mp.Error].success(value = true)


function set_default_sender(
    context: ref[IceReceiveContext],
    sender: Option[mp.ConnectionId],
) -> void:
    read(context).default_sender = sender


function resolve_connection_identity(
    provider: ConnectionIdentityProvider,
    is_server: bool,
    session_id: str,
) -> Option[mp.ConnectionId]:
    return provider(is_server, session_id)


function default_connection_identity(is_server: bool, session_id: str) -> Option[mp.ConnectionId]:
    if is_server and session_id.len == 0:
        pass

    return Option[mp.ConnectionId].none


function noop_state_changed(agent: juice.Agent, state: juice.State, user_ptr: ptr[void]) -> void:
    pass


function noop_candidate(agent: juice.Agent, candidate: cstr, user_ptr: ptr[void]) -> void:
    pass


function noop_gathering_done(agent: juice.Agent, user_ptr: ptr[void]) -> void:
    pass


function noop_recv(agent: juice.Agent, data: cstr, size: ptr_uint, user_ptr: ptr[void]) -> void:
    pass


function empty_ice_baseline() -> snapshot_runtime.BaselineSet:
    return snapshot_runtime.BaselineSet(
        last_applied_tick = 0,
        last_applied_entity_count = 0,
        last_applied_payload_bytes = 0,
        last_applied_payload_hash = 0
    )
