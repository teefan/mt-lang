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


public function error(code: ErrorCode, message: str) -> Error:
    return Error(code = code, message = message)


public function default_config() -> Config:
    return Config(
        snapshot_tick_hz = 20,
        max_entities = 4096,
        max_rpcs_per_tick = 1024,
    )
