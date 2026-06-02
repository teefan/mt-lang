import std.multiplayer.protocol as protocol
import std.multiplayer.registry as registry
import std.multiplayer.world as world
import std.multiplayer.rpc as rpc_runtime
import std.multiplayer.snapshot as snapshot
import std.multiplayer.session as session
import std.multiplayer.lockstep as lockstep
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
public type TickBudgetPlan = protocol.TickBudgetPlan
public type TickDispatchReport = protocol.TickDispatchReport
public type ConnectionStats = protocol.ConnectionStats
public type WeightedConnection = protocol.WeightedConnection
public type StateDescriptor = registry.StateDescriptor
public type RpcDescriptor = registry.RpcDescriptor
public type Registry = registry.Registry
public type World = world.World
public type WorldRole = world.WorldRole
public type EntityRecord = world.EntityRecord
public type Ownership = world.Ownership
public type IncomingRpcPacket = rpc_runtime.IncomingRpcPacket
public type DispatchError = rpc_runtime.DispatchError
public type Snapshot = snapshot.Snapshot
public type DeltaFrame = snapshot.DeltaFrame
public type BaselineSet = snapshot.BaselineSet
public type IncomingSnapshotPacket = snapshot.IncomingSnapshotPacket
public type SlotEntry = session.SlotEntry
public type SlotRoster = session.SlotRoster
public type TurnId = lockstep.TurnId
public type CommandPacketHeader = lockstep.CommandPacketHeader
public type ChecksumReport = lockstep.ChecksumReport
public type DesyncReport = lockstep.DesyncReport
public type TurnStatus = lockstep.TurnStatus
public type IncomingCommandPacket = lockstep.IncomingCommandPacket
public type IncomingChecksumPacket = lockstep.IncomingChecksumPacket
public type Policy = relevancy.Policy
public type PolicyKind = relevancy.PolicyKind
public type CellCoord = relevancy.CellCoord
public type GridCell = spatial.GridCell
public type GridIndex = spatial.GridIndex
public type TypedRpcRoute = rpc_runtime.TypedRpcRoute
public type TypedRpcDispatchTable = rpc_runtime.TypedRpcDispatchTable
public type BindingsInstaller = fn(builder: ptr[BindingsBuilder]) -> Result[ptr_uint, Error]

public struct BindingsBuilder:
    registry: Registry
    typed_rpcs: TypedRpcDispatchTable

public attribute[struct] replicated(authority: Authority)
public attribute[struct] sync_defaults(mode: TransferMode, channel: ubyte, rate_hz: uint, target: SyncTarget)
public attribute[field] sync(mode: TransferMode, channel: ubyte, rate_hz: uint, target: SyncTarget)
public attribute[callable] rpc(direction: RpcDirection, mode: TransferMode, channel: ubyte, require_owner: bool)


extending BindingsBuilder:
    public static function create() -> BindingsBuilder:
        return BindingsBuilder(
            registry = Registry.create(),
            typed_rpcs = TypedRpcDispatchTable.create()
        )


    public function state_count() -> ptr_uint:
        return this.registry.state_count()


    public function rpc_count() -> ptr_uint:
        return this.registry.rpc_count()


    public function route_count() -> ptr_uint:
        return this.typed_rpcs.route_count()


    public function is_frozen() -> bool:
        return this.registry.is_frozen()


    public function protocol_hash() -> ulong:
        return this.registry.protocol_hash()


    public mutable function freeze() -> void:
        this.registry.freeze()


    public mutable function apply(installer: BindingsInstaller) -> Result[ptr_uint, Error]:
        return installer(ptr_of(this))


    public mutable function release() -> void:
        this.typed_rpcs.release()
        this.registry.release()


public function error(code: ErrorCode, message: str) -> Error:
    return protocol.error(code, message)


public function default_config() -> Config:
    return protocol.default_config()


public function create_tick_scheduler(max_bytes_per_tick: ptr_uint) -> TickScheduler:
    return protocol.create_tick_scheduler(max_bytes_per_tick)


public function create_tick_budget_plan(total_bytes: ptr_uint, snapshot_ratio_percent: uint) -> TickBudgetPlan:
    return protocol.create_tick_budget_plan(total_bytes, snapshot_ratio_percent)


public function build_bindings_with(installer: BindingsInstaller) -> Result[BindingsBuilder, Error]:
    var builder = BindingsBuilder.create()
    let _ = builder.apply(installer) else as installer_error:
        builder.release()
        return Result[BindingsBuilder, Error].failure(error = installer_error)

    return Result[BindingsBuilder, Error].success(value = builder)


public function build_frozen_bindings_with(installer: BindingsInstaller) -> Result[BindingsBuilder, Error]:
    let builder = build_bindings_with(installer) else as build_error:
        return Result[BindingsBuilder, Error].failure(error = build_error)

    var owned_builder = builder
    owned_builder.freeze()
    return Result[BindingsBuilder, Error].success(value = owned_builder)


public function bind_state_descriptor(builder: ref[BindingsBuilder], descriptor: StateDescriptor) -> Result[bool, Error]:
    unsafe:
        return read(builder).registry.add_state(descriptor)


public function bind_rpc_descriptor(builder: ref[BindingsBuilder], descriptor: RpcDescriptor) -> Result[bool, Error]:
    unsafe:
        return read(builder).registry.add_rpc(descriptor)


public function bind_typed_rpc_descriptor(
    builder: ref[BindingsBuilder],
    descriptor: RpcDescriptor,
    handler: fn(context: RpcContext, payload: span[ubyte]) -> Result[bool, DispatchError],
) -> Result[bool, Error]:
    unsafe:
        let registry_ref = ref_of(read(builder).registry)
        let routes_ref = ref_of(read(builder).typed_rpcs)

        if read(registry_ref).is_frozen():
            return Result[bool, Error].failure(error = error(
                ErrorCode.registry_frozen,
                "registry is already frozen"
            ))

        if read(registry_ref).has_rpc_descriptor(descriptor):
            return Result[bool, Error].failure(error = error(
                ErrorCode.already_registered,
                "rpc descriptor is already registered"
            ))

        if rpc_runtime.typed_rpc_find_route(read(routes_ref).routes.as_span(), descriptor) != null:
            return Result[bool, Error].failure(error = error(
                ErrorCode.already_registered,
                "typed rpc route is already registered"
            ))

        if rpc_runtime.typed_rpc_find_route_by_wire_identity(read(routes_ref).routes.as_span(), descriptor) != null:
            return Result[bool, Error].failure(error = error(
                ErrorCode.already_registered,
                "typed rpc route collides with an existing channel/direction/payload-size identity"
            ))

        let rpc_added = read(registry_ref).add_rpc(descriptor) else as registry_error:
            return Result[bool, Error].failure(error = registry_error)
        if not rpc_added:
            return Result[bool, Error].success(value = false)

        let route_added = read(routes_ref).register_route(descriptor, handler) else as route_error:
            return Result[bool, Error].failure(error = route_error)
        return Result[bool, Error].success(value = route_added)


public function install_state_and_typed_rpc[T](
    builder: ptr[BindingsBuilder],
    state_descriptor: StateDescriptor,
    descriptor: RpcDescriptor,
    handler: fn(context: RpcContext, payload: span[ubyte]) -> Result[bool, DispatchError],
) -> Result[ptr_uint, Error]:
    let builder_ref = unsafe: ref_of(read(builder))
    var applied: ptr_uint = 0

    match bind_state_descriptor(builder_ref, state_descriptor):
        Result.failure as bind_error:
            return Result[ptr_uint, Error].failure(error = bind_error.error)
        Result.success as state_bound:
            if state_bound.value:
                applied += 1

    match bind_typed_rpc_descriptor(builder_ref, descriptor, handler):
        Result.failure as bind_error:
            return Result[ptr_uint, Error].failure(error = bind_error.error)
        Result.success as rpc_bound:
            if rpc_bound.value:
                applied += 1

    return Result[ptr_uint, Error].success(value = applied)


public function state_descriptor[T]() -> StateDescriptor:
    return registry.state_descriptor[T]()


public function bind_state[T](builder: ref[BindingsBuilder]) -> Result[bool, Error]:
    fatal(c"std.multiplayer.bind_state is compiler-lowered and must be called with ref[BindingsBuilder] plus a concrete replicated type argument")


public function rpc_descriptor(target: callable_handle) -> RpcDescriptor:
    fatal(c"std.multiplayer.rpc_descriptor is compiler-lowered and must be called with callable_of(name) where name has @[std.multiplayer.rpc(...)]")


public function bind_rpc(builder: ref[BindingsBuilder], target: callable_handle) -> Result[bool, Error]:
    fatal(c"std.multiplayer.bind_rpc is compiler-lowered and must be called with ref[BindingsBuilder] and callable_of(name) where name has @[std.multiplayer.rpc(...)]")


public function state_wire_size[T]() -> ptr_uint:
    fatal(c"std.multiplayer.state_wire_size is compiler-lowered and must be called with a @[std.multiplayer.replicated(...)] struct")


public function rpc_payload_size(target: callable_handle) -> ptr_uint:
    fatal(c"std.multiplayer.rpc_payload_size is compiler-lowered and must be called with callable_of(name) where name has @[std.multiplayer.rpc(...)]")


public function bind_typed_rpc(
    builder: ref[BindingsBuilder],
    target: callable_handle,
    handler: fn(context: RpcContext, payload: span[ubyte]) -> Result[bool, DispatchError],
) -> Result[bool, Error]:
    fatal(c"std.multiplayer.bind_typed_rpc is compiler-lowered and must be called with ref[BindingsBuilder], callable_of(name), and a typed rpc dispatch handler")
