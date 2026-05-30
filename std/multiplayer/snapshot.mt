import std.multiplayer.protocol as protocol
import std.multiplayer.wire as wire
import std.bytes as bytes
import std.vec as vec

const snapshot_header_bytes: ptr_uint = 20

public struct Snapshot:
    tick: protocol.Tick
    entity_count: ptr_uint
    payload_bytes: ptr_uint
    payload_hash: ulong

public struct DeltaFrame:
    tick: protocol.Tick
    baseline_tick: protocol.Tick
    changed_entity_count: ptr_uint
    payload_changed: bool

public struct BaselineSet:
    last_applied_tick: protocol.Tick
    last_applied_entity_count: ptr_uint
    last_applied_payload_bytes: ptr_uint
    last_applied_payload_hash: ulong

public struct IncomingSnapshotPacket:
    header: protocol.SnapshotPacketHeader
    sender: Option[protocol.ConnectionId]
    channel: uint
    payload: bytes.Bytes


public function capture(tick: protocol.Tick, entity_count: ptr_uint) -> Snapshot:
    return Snapshot(
        tick = tick,
        entity_count = entity_count,
        payload_bytes = 0,
        payload_hash = 0
    )


public function capture_payload(tick: protocol.Tick, entity_count: ptr_uint, payload: span[ubyte]) -> Snapshot:
    return Snapshot(
        tick = tick,
        entity_count = entity_count,
        payload_bytes = payload.len,
        payload_hash = payload_fingerprint(payload)
    )


public function diff(current: Snapshot, baseline: Snapshot) -> DeltaFrame:
    var changed_entity_count: ptr_uint = 0
    let payload_changed = current.payload_bytes != baseline.payload_bytes or current.payload_hash != baseline.payload_hash

    if payload_changed and current.entity_count > 0:
        changed_entity_count = current.entity_count
    else:
        if current.entity_count >= baseline.entity_count:
            changed_entity_count = current.entity_count - baseline.entity_count
        else:
            changed_entity_count = baseline.entity_count - current.entity_count

    return DeltaFrame(
        tick = current.tick,
        baseline_tick = baseline.tick,
        changed_entity_count = changed_entity_count,
        payload_changed = payload_changed
    )


public function diff_payload(
    current_tick: protocol.Tick,
    current_entity_count: ptr_uint,
    current_payload: span[ubyte],
    baseline_tick: protocol.Tick,
    baseline_entity_count: ptr_uint,
    baseline_payload: span[ubyte],
) -> DeltaFrame:
    let current = capture_payload(current_tick, current_entity_count, current_payload)
    let baseline = capture_payload(baseline_tick, baseline_entity_count, baseline_payload)
    return diff(current, baseline)


public function apply(snapshot: Snapshot, baselines: ref[BaselineSet]) -> void:
    baselines.last_applied_tick = snapshot.tick
    baselines.last_applied_entity_count = snapshot.entity_count
    baselines.last_applied_payload_bytes = snapshot.payload_bytes
    baselines.last_applied_payload_hash = snapshot.payload_hash


public function snapshot_from_baseline(baselines: BaselineSet) -> Snapshot:
    return Snapshot(
        tick = baselines.last_applied_tick,
        entity_count = baselines.last_applied_entity_count,
        payload_bytes = baselines.last_applied_payload_bytes,
        payload_hash = baselines.last_applied_payload_hash
    )


public function should_send_against_baseline(current: Snapshot, baselines: BaselineSet) -> bool:
    if baselines.last_applied_tick == 0:
        return true

    let baseline_snapshot = snapshot_from_baseline(baselines)
    let delta = diff(current, baseline_snapshot)
    return delta.payload_changed or delta.changed_entity_count > 0


public function apply_payload(
    tick: protocol.Tick,
    entity_count: ptr_uint,
    payload: span[ubyte],
    baselines: ref[BaselineSet],
) -> void:
    let snapshot = capture_payload(tick, entity_count, payload)
    apply(snapshot, baselines)


public function apply_from_packet(payload: span[ubyte], baselines: ref[BaselineSet]) -> Result[bool, protocol.Error]:
    let header = decode_header(payload) else as header_error:
        return Result[bool, protocol.Error].failure(error = header_error)

    unsafe:
        let body = span[ubyte](
            data = payload.data + snapshot_header_bytes,
            len = payload.len - snapshot_header_bytes
        )
        apply_payload(header.tick, header.entity_count, body, baselines)

    return Result[bool, protocol.Error].success(value = true)


public function encode_header(header: protocol.SnapshotPacketHeader) -> array[ubyte, 20]:
    let tick = wire.encode_u64_be(header.tick)
    let baseline_tick = wire.encode_u64_be(header.baseline_tick)
    let entity_count = wire.encode_u32_be(uint<-header.entity_count)
    return array[ubyte, 20](
        tick[0],
        tick[1],
        tick[2],
        tick[3],
        tick[4],
        tick[5],
        tick[6],
        tick[7],
        baseline_tick[0],
        baseline_tick[1],
        baseline_tick[2],
        baseline_tick[3],
        baseline_tick[4],
        baseline_tick[5],
        baseline_tick[6],
        baseline_tick[7],
        entity_count[0],
        entity_count[1],
        entity_count[2],
        entity_count[3]
    )


public function decode_header(input: span[ubyte]) -> Result[protocol.SnapshotPacketHeader, protocol.Error]:
    if input.len < snapshot_header_bytes:
        return Result[protocol.SnapshotPacketHeader, protocol.Error].failure(
            error = protocol.error(protocol.ErrorCode.invalid_argument, "snapshot packet is too small")
        )

    let tick = wire.decode_u64_be(input, 0)
    let baseline_tick = wire.decode_u64_be(input, 8)
    let entity_count = ptr_uint<-wire.decode_u32_be(input, 16)
    return Result[protocol.SnapshotPacketHeader, protocol.Error].success(
        value = protocol.SnapshotPacketHeader(
            tick = tick,
            baseline_tick = baseline_tick,
            entity_count = entity_count
        )
    )


public function build_payload(header: protocol.SnapshotPacketHeader, payload: span[ubyte]) -> bytes.Bytes:
    var combined = vec.Vec[ubyte].with_capacity(snapshot_header_bytes + payload.len)
    defer combined.release()

    combined.append_array(encode_header(header))
    combined.append_span(payload)
    return bytes.Bytes.copy(combined.as_span())


public function enqueue_incoming(
    queue: ref[vec.Vec[IncomingSnapshotPacket]],
    sender: Option[protocol.ConnectionId],
    channel: uint,
    payload: span[ubyte],
) -> Result[bool, protocol.Error]:
    let header = decode_header(payload) else as header_error:
        return Result[bool, protocol.Error].failure(error = header_error)

    unsafe:
        let body = span[ubyte](
            data = payload.data + snapshot_header_bytes,
            len = payload.len - snapshot_header_bytes
        )
        queue.push(IncomingSnapshotPacket(
            header = header,
            sender = sender,
            channel = channel,
            payload = bytes.Bytes.copy(body)
        ))

    return Result[bool, protocol.Error].success(value = true)


public function dequeue_incoming(queue: ref[vec.Vec[IncomingSnapshotPacket]]) -> Option[IncomingSnapshotPacket]:
    if queue.len() == 0:
        return Option[IncomingSnapshotPacket].none

    match queue.remove(0):
        Option.some as payload:
            return Option[IncomingSnapshotPacket].some(value = payload.value)
        Option.none:
            return Option[IncomingSnapshotPacket].none


public function release_queue(queue: ref[vec.Vec[IncomingSnapshotPacket]]) -> void:
    while true:
        match queue.pop():
            Option.some as payload:
                var packet = payload.value
                packet.payload.release()
            Option.none:
                queue.release()
                return


extending IncomingSnapshotPacket:
    public mutable function release() -> void:
        this.payload.release()


function payload_fingerprint(payload: span[ubyte]) -> ulong:
    var hash: ulong = 1469598103934665603
    var index: ptr_uint = 0
    while index < payload.len:
        hash = hash ^ ulong<-payload[index]
        hash = hash * 1099511628211
        index += 1

    return hash
