import std.multiplayer.protocol as protocol
import std.multiplayer.registry as registry
import std.multiplayer.world as world
import std.multiplayer.rpc as rpc_runtime
import std.multiplayer.snapshot as snapshot
import std.multiplayer.relevancy as relevancy
import std.multiplayer.spatial as spatial


public type ConnectionId = protocol.ConnectionId
public type EntityId = protocol.EntityId
public type Tick = protocol.Tick
public type Authority = protocol.Authority
public type TransferMode = protocol.TransferMode
public type SyncTarget = protocol.SyncTarget
public type RpcDirection = protocol.RpcDirection
public type ErrorCode = protocol.ErrorCode
public type Error = protocol.Error
public type Config = protocol.Config
public type RpcContext = protocol.RpcContext
public type PacketKind = protocol.PacketKind
public type HandshakeHello = protocol.HandshakeHello
public type HandshakeWelcome = protocol.HandshakeWelcome
public type HandshakeReject = protocol.HandshakeReject
public type SnapshotPacketHeader = protocol.SnapshotPacketHeader
public type RpcPacketHeader = protocol.RpcPacketHeader
public type TickBudget = protocol.TickBudget
public type TickReservation = protocol.TickReservation
public type TickScheduler = protocol.TickScheduler
public type StateDescriptor = registry.StateDescriptor
public type RpcDescriptor = registry.RpcDescriptor
public type Registry = registry.Registry
public type World = world.World
public type WorldRole = world.WorldRole
public type EntityRecord = world.EntityRecord
public type Ownership = world.Ownership
public type OutgoingRpc = rpc_runtime.OutgoingRpc
public type IncomingRpc = rpc_runtime.IncomingRpc
public type IncomingRpcPacket = rpc_runtime.IncomingRpcPacket
public type DispatchError = rpc_runtime.DispatchError
public type RpcDispatchRoute = rpc_runtime.RpcDispatchRoute
public type RpcDispatchTable = rpc_runtime.RpcDispatchTable
public type Snapshot = snapshot.Snapshot
public type DeltaFrame = snapshot.DeltaFrame
public type BaselineSet = snapshot.BaselineSet
public type IncomingSnapshotPacket = snapshot.IncomingSnapshotPacket
public type Policy = relevancy.Policy
public type PolicyKind = relevancy.PolicyKind
public type CellCoord = relevancy.CellCoord
public type GridCell = spatial.GridCell
public type GridIndex = spatial.GridIndex


public attribute[struct] replicated(authority: Authority)
public attribute[struct] sync_defaults(mode: TransferMode, channel: ubyte, rate_hz: uint, target: SyncTarget)
public attribute[field] sync(mode: TransferMode, channel: ubyte, rate_hz: uint, target: SyncTarget)
public attribute[callable] rpc(direction: RpcDirection, mode: TransferMode, channel: ubyte, require_owner: bool)


public function error(code: ErrorCode, message: str) -> Error:
    return protocol.error(code, message)


public function default_config() -> Config:
    return protocol.default_config()


public function create_tick_scheduler(max_bytes_per_tick: ptr_uint) -> TickScheduler:
    return protocol.create_tick_scheduler(max_bytes_per_tick)


public function state_descriptor[T]() -> StateDescriptor:
    return registry.state_descriptor[T]()


public function rpc_descriptor(target: callable_handle) -> RpcDescriptor:
    fatal(c"std.multiplayer.rpc_descriptor is compiler-lowered and must be called with callable_of(name) where name has @[std.multiplayer.rpc(...)]")
