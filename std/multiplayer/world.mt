import std.multiplayer.protocol as protocol
import std.multiplayer.registry as registry
import std.multiplayer.snapshot as snapshot_runtime
import std.multiplayer.wire as wire
import std.bytes as bytes
import std.mem.heap as heap
import std.str as text
import std.vec as vec

public type Error = protocol.Error
public type ErrorCode = protocol.ErrorCode
public type ConnectionId = protocol.ConnectionId
public type EntityId = protocol.EntityId

public enum WorldRole: ubyte
    server = 0
    client = 1

public struct Ownership:
    owner: Option[ConnectionId]

public struct EntityRecord:
    entity: EntityId
    descriptor: registry.StateDescriptor
    owner: Option[ConnectionId]
    state_size: ptr_uint
    state_storage: ptr[void]?

public struct World:
    role: WorldRole
    config: protocol.Config
    protocol_hash_value: ulong
    registered_states: vec.Vec[registry.StateDescriptor]
    registered_rpcs: vec.Vec[registry.RpcDescriptor]
    entities: vec.Vec[EntityRecord]
    next_entity_id: EntityId


extending World:
    public static function create(
        source_registry: registry.Registry,
        config: protocol.Config,
        role: WorldRole,
    ) -> Result[World, Error]:
        if not source_registry.frozen:
            return Result[World, Error].failure(
                error = protocol.error(ErrorCode.registry_not_frozen, "world creation requires a frozen registry")
            )

        var result = World(
            role = role,
            config = config,
            protocol_hash_value = source_registry.protocol_hash_value,
            registered_states = vec.Vec[registry.StateDescriptor].create(),
            registered_rpcs = vec.Vec[registry.RpcDescriptor].create(),
            entities = vec.Vec[EntityRecord].create(),
            next_entity_id = 1
        )
        result.registered_states.append_span(source_registry.states.as_span())
        result.registered_rpcs.append_span(source_registry.rpcs.as_span())
        return Result[World, Error].success(value = result)


    public function protocol_hash() -> ulong:
        return this.protocol_hash_value


    public function entity_count() -> ptr_uint:
        return this.entities.len()


    public function snapshot_state_signature(tick: protocol.Tick) -> snapshot_runtime.Snapshot:
        var payload_bytes: ptr_uint = 0
        var payload_hash: ulong = 1469598103934665603

        var entity_index: ptr_uint = 0
        while entity_index < this.entities.len():
            let entity = this.entities.get(entity_index)
            if entity != null:
                unsafe:
                    let record = read(entity)
                    payload_bytes += record.state_size
                    if record.state_storage != null and record.state_size > 0:
                        let state_bytes = ptr[ubyte]<-record.state_storage
                        var byte_index: ptr_uint = 0
                        while byte_index < record.state_size:
                            payload_hash = payload_hash ^ ulong<-read(state_bytes + byte_index)
                            payload_hash = payload_hash * 1099511628211
                            byte_index += 1

            entity_index += 1

        if payload_bytes == 0:
            payload_hash = 0

        return snapshot_runtime.Snapshot(
            tick = tick,
            entity_count = this.entities.len(),
            payload_bytes = payload_bytes,
            payload_hash = payload_hash
        )


    public function apply_snapshot_signature(tick: protocol.Tick, baselines: ref[snapshot_runtime.BaselineSet]) -> void:
        let signature = this.snapshot_state_signature(tick)
        snapshot_runtime.apply(signature, baselines)


    public function encode_snapshot_payload() -> Result[bytes.Bytes, Error]:
        var estimated_size: ptr_uint = 4
        var estimate_index: ptr_uint = 0
        while estimate_index < this.entities.len():
            let entity = this.entities.get(estimate_index)
            if entity != null:
                unsafe:
                    let record = read(entity)
                    estimated_size += 16 + record.state_size
            estimate_index += 1

        var output = vec.Vec[ubyte].with_capacity(estimated_size)
        defer output.release()

        output.append_array(wire.encode_u32_be(uint<-this.entities.len()))

        var index: ptr_uint = 0
        while index < this.entities.len():
            let entity = this.entities.get(index)
            if entity != null:
                unsafe:
                    let record = read(entity)
                    if record.descriptor.encode_full_binding != registry.expected_state_encode_full_binding(record.descriptor):
                        return Result[bytes.Bytes, Error].failure(
                            error = protocol.error(
                                ErrorCode.invalid_argument,
                                "state descriptor encode_full binding mismatch"
                            )
                        )

                    output.append_array(wire.encode_u32_be(uint<-record.entity))
                    output.append_array(wire.encode_u64_be(record.descriptor.schema_hash))
                    output.append_array(wire.encode_u32_be(uint<-record.state_size))
                    if record.state_storage != null and record.state_size > 0:
                        let state_bytes = span[ubyte](
                            data = ptr[ubyte]<-record.state_storage,
                            len = record.state_size
                        )
                        output.append_span(state_bytes)
            index += 1

        return Result[bytes.Bytes, Error].success(value = bytes.Bytes.copy(output.as_span()))


    public mutable function apply_snapshot_payload(payload: span[ubyte]) -> Result[ptr_uint, Error]:
        if payload.len < 4:
            return Result[ptr_uint, Error].failure(
                error = protocol.error(ErrorCode.invalid_argument, "snapshot payload is too small")
            )

        var applied: ptr_uint = 0
        var offset: ptr_uint = 0
        let entity_count = ptr_uint<-wire.decode_u32_be(payload, offset)
        offset += 4

        var index: ptr_uint = 0
        while index < entity_count:
            if payload.len - offset < 16:
                return Result[ptr_uint, Error].failure(
                    error = protocol.error(ErrorCode.invalid_argument, "snapshot payload entry header is truncated")
                )

            let entity = protocol.EntityId<-wire.decode_u32_be(payload, offset)
            offset += 4
            let schema_hash = wire.decode_u64_be(payload, offset)
            offset += 8
            let state_size = ptr_uint<-wire.decode_u32_be(payload, offset)
            offset += 4

            if payload.len - offset < state_size:
                return Result[ptr_uint, Error].failure(
                    error = protocol.error(ErrorCode.invalid_argument, "snapshot payload entry body is truncated")
                )

            let record = find_entity_record(this.entities.as_span(), entity)
            if record != null:
                unsafe:
                    let current = read(record)
                    if (
                        current.descriptor.schema_hash == schema_hash
                        and current.state_size == state_size
                        and current.state_storage != null
                    ):
                        if current.descriptor.decode_full_binding != registry.expected_state_decode_full_binding(current.descriptor):
                            return Result[ptr_uint, Error].failure(
                                error = protocol.error(
                                    ErrorCode.invalid_argument,
                                    "state descriptor decode_full binding mismatch"
                                )
                            )

                        if current.descriptor.apply_delta_binding != registry.expected_state_apply_delta_binding(current.descriptor):
                            return Result[ptr_uint, Error].failure(
                                error = protocol.error(
                                    ErrorCode.invalid_argument,
                                    "state descriptor apply_delta binding mismatch"
                                )
                            )

                        copy_state_bytes(
                            ptr[ubyte]<-current.state_storage,
                            payload.data + offset,
                            state_size
                        )
                        applied += 1

            offset += state_size
            index += 1

        if offset != payload.len:
            return Result[ptr_uint, Error].failure(
                error = protocol.error(ErrorCode.invalid_argument, "snapshot payload has trailing bytes")
            )

        return Result[ptr_uint, Error].success(value = applied)


    public mutable function drain_incoming_snapshots(
        queue: ref[vec.Vec[snapshot_runtime.IncomingSnapshotPacket]],
        baselines: ref[snapshot_runtime.BaselineSet],
    ) -> Result[ptr_uint, Error]:
        var processed: ptr_uint = 0
        while true:
            var packet = snapshot_runtime.dequeue_incoming(queue) else:
                return Result[ptr_uint, Error].success(value = processed)

            match this.apply_snapshot_payload(packet.payload.as_span()):
                Result.success:
                    snapshot_runtime.apply_payload(
                        packet.header.tick,
                        packet.header.entity_count,
                        packet.payload.as_span(),
                        baselines
                    )
                    processed += 1
                Result.failure as payload:
                    packet.release()
                    return Result[ptr_uint, Error].failure(error = payload.error)

            packet.release()


    public mutable function release() -> void:
        release_entity_storage(ref_of(this.entities))
        this.entities.release()
        this.registered_states.release()
        this.registered_rpcs.release()
        this.next_entity_id = 0
        this.protocol_hash_value = 0


    public mutable function spawn[T](state: T, owner: Option[ConnectionId]) -> Result[EntityId, Error]:
        let descriptor = resolve_spawn_descriptor(this.registered_states.as_span()) else:
            return Result[EntityId, Error].failure(
                error = protocol.error(ErrorCode.not_registered, "spawn requires one registered state descriptor"),
            )

        return this.spawn_with_descriptor(descriptor, state, owner)


    public mutable function spawn_with_descriptor[T](
        descriptor: registry.StateDescriptor,
        state: T,
        owner: Option[ConnectionId],
    ) -> Result[EntityId, Error]:
        if not has_registered_state_descriptor(this.registered_states.as_span(), descriptor):
            return Result[EntityId, Error].failure(
                error = protocol.error(ErrorCode.not_registered, "state descriptor is not registered")
            )

        match owner:
            Option.some:
                if descriptor.authority == protocol.Authority.server:
                    return Result[EntityId, Error].failure(
                        error = protocol.error(ErrorCode.unsupported, "server-authoritative state cannot use an owner")
                    )
            Option.none:
                pass

        if this.entities.len() >= this.config.max_entities:
            return Result[EntityId, Error].failure(
                error = protocol.error(ErrorCode.invalid_argument, "world has reached max_entities capacity")
            )

        let entity = this.next_entity_id
        if entity == 0:
            return Result[EntityId, Error].failure(
                error = protocol.error(ErrorCode.unsupported, "entity id space is exhausted")
            )

        let size = ptr_uint<-size_of(T)
        let state_storage = heap.must_alloc_aligned[T](1)
        unsafe:
            read(state_storage) = state

        this.next_entity_id += 1
        this.entities.push(EntityRecord(
            entity = entity,
            descriptor = descriptor,
            owner = owner,
            state_size = size,
            state_storage = unsafe: ptr[void]<-state_storage
        ))
        return Result[EntityId, Error].success(value = entity)


    public mutable function despawn(entity: EntityId) -> Result[bool, Error]:
        match this.entities.find_index(proc(candidate: ptr[EntityRecord]) -> bool:
            unsafe: read(candidate).entity == entity
        ):
            Option.some as payload:
                release_entity_record(ptr_of(this.entities), payload.value)
                this.entities.remove(payload.value)
                return Result[bool, Error].success(value = true)
            Option.none:
                return Result[bool, Error].success(value = false)


    public mutable function transfer_ownership(entity: EntityId, owner: Option[ConnectionId]) -> Result[bool, Error]:
        let record = this.entities.find(proc(candidate: ptr[EntityRecord]) -> bool:
            unsafe: read(candidate).entity == entity
        ) else:
            return Result[bool, Error].success(value = false)

        unsafe:
            let current = read(record)
            if current.descriptor.authority != protocol.Authority.owner:
                return Result[bool, Error].failure(
                    error = protocol.error(ErrorCode.unsupported, "ownership transfer requires owner authority")
                )

            if same_owner(current.owner, owner):
                return Result[bool, Error].success(value = false)

            read(record).owner = owner
            return Result[bool, Error].success(value = true)


    public function state_ptr[T](entity: EntityId) -> ptr[T]?:
        let descriptor = resolve_spawn_descriptor(this.registered_states.as_span()) else:
            return null

        return this.state_ptr_with_descriptor[T](entity, descriptor)


    public function state_ptr_with_descriptor[T](
        entity: EntityId,
        descriptor: registry.StateDescriptor,
    ) -> ptr[T]?:
        let record = find_entity_record(this.entities.as_span(), entity) else:
            return null

        unsafe:
            let current = read(record)
            if not state_descriptor_matches(current.descriptor, descriptor):
                return null

            if current.state_size != ptr_uint<-size_of(T):
                return null

            return ptr[T]<-current.state_storage


    public function state_copy[T](entity: EntityId) -> Option[T]:
        let descriptor = resolve_spawn_descriptor(this.registered_states.as_span()) else:
            return Option[T].none

        return this.state_copy_with_descriptor[T](entity, descriptor)


    public function state_copy_with_descriptor[T](
        entity: EntityId,
        descriptor: registry.StateDescriptor,
    ) -> Option[T]:
        let state = this.state_ptr_with_descriptor[T](entity, descriptor) else:
            return Option[T].none

        unsafe:
            return Option[T].some(value = read(state))


function resolve_spawn_descriptor(
    registered_states: span[registry.StateDescriptor],
) -> Option[registry.StateDescriptor]:
    if registered_states.len != 1:
        return Option[registry.StateDescriptor].none

    unsafe:
        return Option[registry.StateDescriptor].some(value = read(registered_states.data))


function has_registered_state_descriptor(
    registered_states: span[registry.StateDescriptor],
    descriptor: registry.StateDescriptor,
) -> bool:
    var index: ptr_uint = 0
    while index < registered_states.len:
        unsafe:
            if state_descriptor_matches(read(registered_states.data + index), descriptor):
                return true
        index += 1

    return false


function state_descriptor_matches(
    left: registry.StateDescriptor,
    right: registry.StateDescriptor,
) -> bool:
    return left.schema_hash == right.schema_hash and left.name.equal(right.name)


function find_entity_record(
    entities: span[EntityRecord],
    entity: EntityId,
) -> ptr[EntityRecord]?:
    var index: ptr_uint = 0
    while index < entities.len:
        unsafe:
            let record = entities.data + index
            if read(record).entity == entity:
                return record
        index += 1

    return null


function release_entity_record(entities: ptr[vec.Vec[EntityRecord]], index: ptr_uint) -> void:
    unsafe:
        let data = read(entities).data else:
            return

        let record_ptr = ptr[EntityRecord]<-data + index
        let storage = read(record_ptr).state_storage
        if storage != null:
            heap.release_bytes(storage)
            read(record_ptr).state_storage = null


function release_entity_storage(entities: ref[vec.Vec[EntityRecord]]) -> void:
    var index: ptr_uint = 0
    while index < entities.len():
        release_entity_record(ptr_of(entities), index)
        index += 1


function same_owner(left: Option[ConnectionId], right: Option[ConnectionId]) -> bool:
    match left:
        Option.some as left_payload:
            match right:
                Option.some as right_payload:
                    return left_payload.value == right_payload.value
                Option.none:
                    return false
        Option.none:
            match right:
                Option.some:
                    return false
                Option.none:
                    return true


function copy_state_bytes(destination: ptr[ubyte], source: ptr[ubyte], size: ptr_uint) -> void:
    var index: ptr_uint = 0
    while index < size:
        unsafe:
            read(destination + index) = read(source + index)
        index += 1
