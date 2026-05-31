public type ConnectionId = ulong
public type EntityId = ulong
public type Tick = ulong

public enum Authority: ubyte
    server = 0
    owner = 1

public enum TransferMode: ubyte
    unreliable = 0
    unreliable_ordered = 1
    reliable = 2

public enum SyncTarget: ubyte
    observers = 0
    owner = 1

public enum RpcDirection: ubyte
    client_to_server = 0
    server_to_owner = 1
    server_to_connection = 2
    server_to_observers = 3
    server_to_all = 4

public enum ErrorCode: int
    invalid_argument = 1
    already_registered = 2
    registry_not_frozen = 3
    registry_frozen = 4
    not_registered = 5
    not_found = 6
    unsupported = 7
    not_implemented = 8

public struct Error:
    code: ErrorCode
    message: str

public struct Config:
    snapshot_tick_hz: uint
    max_entities: ptr_uint
    max_rpcs_per_tick: ptr_uint

public struct RpcContext:
    sender: Option[ConnectionId]
    tick: Tick

public enum PacketKind: ubyte
    handshake_hello = 0
    handshake_welcome = 1
    handshake_reject = 2
    snapshot = 3
    rpc = 4

public struct HandshakeHello:
    protocol_hash: ulong

public struct HandshakeWelcome:
    protocol_hash: ulong
    connection: ConnectionId

public struct HandshakeReject:
    protocol_hash: ulong
    reason: ErrorCode

public struct SnapshotPacketHeader:
    tick: Tick
    baseline_tick: Tick
    entity_count: ptr_uint

public struct RpcPacketHeader:
    channel: uint
    direction: RpcDirection
    payload_size: ptr_uint

public struct TickBudget:
    max_bytes_per_tick: ptr_uint
    used_bytes_this_tick: ptr_uint

public struct TickReservation:
    tick: Tick
    sequence: ulong
    reserved_bytes: ptr_uint

public struct TickScheduler:
    current_tick: Tick
    next_sequence: ulong
    budget: TickBudget

public struct TickBudgetPlan:
    total_bytes: ptr_uint
    snapshot_bytes: ptr_uint
    rpc_bytes: ptr_uint

public struct TickDispatchReport:
    snapshots_sent: ptr_uint
    rpcs_sent: ptr_uint
    consumed_bytes: ptr_uint


public function error(code: ErrorCode, message: str) -> Error:
    return Error(code = code, message = message)


public function default_config() -> Config:
    return Config(
        snapshot_tick_hz = 20,
        max_entities = 4096,
        max_rpcs_per_tick = 1024
    )


public function create_tick_scheduler(max_bytes_per_tick: ptr_uint) -> TickScheduler:
    return TickScheduler(
        current_tick = 0,
        next_sequence = 0,
        budget = TickBudget(
            max_bytes_per_tick = max_bytes_per_tick,
            used_bytes_this_tick = 0
        )
    )


public function create_tick_budget_plan(total_bytes: ptr_uint, snapshot_ratio_percent: uint) -> TickBudgetPlan:
    if snapshot_ratio_percent >= 100:
        return TickBudgetPlan(total_bytes = total_bytes, snapshot_bytes = total_bytes, rpc_bytes = 0)

    let snapshot_bytes = (total_bytes * ptr_uint<-snapshot_ratio_percent) / 100
    return TickBudgetPlan(
        total_bytes = total_bytes,
        snapshot_bytes = snapshot_bytes,
        rpc_bytes = total_bytes - snapshot_bytes
    )


extending TickScheduler:
    public mutable function begin_tick(tick: Tick) -> void:
        this.current_tick = tick
        this.next_sequence = 0
        this.budget.used_bytes_this_tick = 0


    public function consumed_bytes() -> ptr_uint:
        return this.budget.used_bytes_this_tick


    public function remaining_bytes() -> ptr_uint:
        if this.budget.used_bytes_this_tick >= this.budget.max_bytes_per_tick:
            return 0
        return this.budget.max_bytes_per_tick - this.budget.used_bytes_this_tick


    public mutable function reserve(bytes: ptr_uint) -> Option[TickReservation]:
        if this.budget.used_bytes_this_tick >= this.budget.max_bytes_per_tick:
            return Option[TickReservation].none

        let remaining = this.budget.max_bytes_per_tick - this.budget.used_bytes_this_tick
        if bytes > remaining:
            return Option[TickReservation].none

        let reservation = TickReservation(
            tick = this.current_tick,
            sequence = this.next_sequence,
            reserved_bytes = bytes
        )
        this.next_sequence += 1
        this.budget.used_bytes_this_tick += bytes
        return Option[TickReservation].some(value = reservation)


public struct ConnectionStats:
    latency_ms: uint
    packets_sent: ulong
    packets_received: ulong
    packets_lost: ulong
    bytes_sent: ulong
    bytes_received: ulong
    round_trip_time_ms: uint


public function connection_stats_default() -> ConnectionStats:
    return ConnectionStats(
        latency_ms = 0,
        packets_sent = 0,
        packets_received = 0,
        packets_lost = 0,
        bytes_sent = 0,
        bytes_received = 0,
        round_trip_time_ms = 0
    )


public function packet_kind_from_byte(value: ubyte) -> Option[PacketKind]:
    if value == ubyte<-PacketKind.handshake_hello:
        return Option[PacketKind].some(value = PacketKind.handshake_hello)
    if value == ubyte<-PacketKind.handshake_welcome:
        return Option[PacketKind].some(value = PacketKind.handshake_welcome)
    if value == ubyte<-PacketKind.handshake_reject:
        return Option[PacketKind].some(value = PacketKind.handshake_reject)
    if value == ubyte<-PacketKind.snapshot:
        return Option[PacketKind].some(value = PacketKind.snapshot)
    if value == ubyte<-PacketKind.rpc:
        return Option[PacketKind].some(value = PacketKind.rpc)

    return Option[PacketKind].none
