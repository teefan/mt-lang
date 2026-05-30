import std.multiplayer.protocol as protocol
import std.str as text
import std.vec as vec


public type Error = protocol.Error
public type ErrorCode = protocol.ErrorCode


public struct StateDescriptor:
    name: str
    authority: protocol.Authority
    schema_hash: ulong
    sync_field_count: ptr_uint
    sync_mode: protocol.TransferMode
    sync_channel: uint
    sync_rate_hz: uint
    sync_target: protocol.SyncTarget


public struct RpcDescriptor:
    name: str
    direction: protocol.RpcDirection
    mode: protocol.TransferMode
    channel: uint
    require_owner: bool
    schema_hash: ulong


public struct Registry:
    states: vec.Vec[StateDescriptor]
    rpcs: vec.Vec[RpcDescriptor]
    frozen: bool
    protocol_hash_value: ulong


public function state_descriptor[T]() -> StateDescriptor:
    fatal(c"std.multiplayer.state_descriptor is compiler-lowered and must be called with a @[std.multiplayer.replicated(...)] struct")


extending Registry:
    public static function create() -> Registry:
        return Registry(
            states = vec.Vec[StateDescriptor].create(),
            rpcs = vec.Vec[RpcDescriptor].create(),
            frozen = false,
            protocol_hash_value = 0,
        )


    public function state_count() -> ptr_uint:
        return this.states.len()


    public function rpc_count() -> ptr_uint:
        return this.rpcs.len()


    public function is_frozen() -> bool:
        return this.frozen


    public function protocol_hash() -> ulong:
        return this.protocol_hash_value


    public function has_state_descriptor(descriptor: StateDescriptor) -> bool:
        return this.states.find(proc(candidate: ptr[StateDescriptor]) -> bool:
            unsafe: same_state_descriptor(read(candidate), descriptor)
        ) != null


    public function has_rpc_descriptor(descriptor: RpcDescriptor) -> bool:
        return this.rpcs.find(proc(candidate: ptr[RpcDescriptor]) -> bool:
            unsafe: same_rpc_descriptor(read(candidate), descriptor)
        ) != null


    public mutable function release() -> void:
        this.states.release()
        this.rpcs.release()
        this.frozen = false
        this.protocol_hash_value = 0
        return


    public mutable function add_state(descriptor: StateDescriptor) -> Result[bool, Error]:
        if this.frozen:
            return Result[bool, Error].failure(error = registry_error(ErrorCode.registry_frozen, "registry is already frozen"))

        if has_state_descriptor(this.states.as_span(), descriptor):
            return Result[bool, Error].failure(error = registry_error(ErrorCode.already_registered, "state descriptor is already registered"))

        this.states.push(descriptor)
        return Result[bool, Error].success(value = true)


    public mutable function add_rpc(descriptor: RpcDescriptor) -> Result[bool, Error]:
        if this.frozen:
            return Result[bool, Error].failure(error = registry_error(ErrorCode.registry_frozen, "registry is already frozen"))

        if has_rpc_descriptor(this.rpcs.as_span(), descriptor):
            return Result[bool, Error].failure(error = registry_error(ErrorCode.already_registered, "rpc descriptor is already registered"))

        this.rpcs.push(descriptor)
        return Result[bool, Error].success(value = true)


    public mutable function freeze() -> void:
        if this.frozen:
            return

        this.protocol_hash_value = compute_protocol_hash(this.states.as_span(), this.rpcs.as_span())
        this.frozen = true
        return


function registry_error(code: ErrorCode, message: str) -> Error:
    return protocol.error(code, message)


function same_state_descriptor(left: StateDescriptor, right: StateDescriptor) -> bool:
    return left.schema_hash == right.schema_hash and left.name.equal(right.name)


function same_rpc_descriptor(left: RpcDescriptor, right: RpcDescriptor) -> bool:
    return left.schema_hash == right.schema_hash and left.name.equal(right.name)


function has_state_descriptor(descriptors: span[StateDescriptor], target: StateDescriptor) -> bool:
    var index: ptr_uint = 0
    while index < descriptors.len:
        unsafe:
            if same_state_descriptor(read(descriptors.data + index), target):
                return true
        index += 1

    return false


function has_rpc_descriptor(descriptors: span[RpcDescriptor], target: RpcDescriptor) -> bool:
    var index: ptr_uint = 0
    while index < descriptors.len:
        unsafe:
            if same_rpc_descriptor(read(descriptors.data + index), target):
                return true
        index += 1

    return false


function compute_protocol_hash(states: span[StateDescriptor], rpcs: span[RpcDescriptor]) -> ulong:
    var hash: ulong = 17
    var state_index: ptr_uint = 0
    while state_index < states.len:
        unsafe:
            hash = hash * 31 + read(states.data + state_index).schema_hash
        state_index += 1

    var rpc_index: ptr_uint = 0
    while rpc_index < rpcs.len:
        unsafe:
            hash = hash * 31 + read(rpcs.data + rpc_index).schema_hash
        rpc_index += 1

    return hash
