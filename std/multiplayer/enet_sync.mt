import std.bytes as bytes
import std.multiplayer as mp
import std.multiplayer.enet as mp_enet

public struct ObserverStateSync[T]:
    descriptor: mp.StateDescriptor
    local_tick_hz: uint
    entity_count: ptr_uint


extending ObserverStateSync[T]:
    public static function create(
        descriptor: mp.StateDescriptor,
        local_tick_hz: uint,
        entity_count: ptr_uint,
    ) -> ObserverStateSync[T]:
        return ObserverStateSync[T](
            descriptor = descriptor,
            local_tick_hz = local_tick_hz,
            entity_count = entity_count,
        )


    public function should_emit(tick: mp.Tick) -> bool:
        if this.descriptor.sync_field_count == 0:
            return false

        if this.descriptor.sync_target != mp.SyncTarget.observers:
            return false

        if this.descriptor.sync_rate_hz == 0:
            return false

        if this.local_tick_hz == 0:
            return false

        if this.descriptor.sync_rate_hz >= this.local_tick_hz:
            return true

        let stride_hz = this.local_tick_hz / this.descriptor.sync_rate_hz
        if stride_hz == 0:
            return true

        return tick % ulong<-stride_hz == 0


    public function snapshot_header(tick: mp.Tick) -> mp.SnapshotPacketHeader:
        return mp.SnapshotPacketHeader(
            tick = tick,
            baseline_tick = previous_tick(tick),
            entity_count = this.entity_count,
        )


public function broadcast_observer_state[T](
    sync: ObserverStateSync[T],
    server: ref[mp_enet.Server],
    tick: mp.Tick,
    state: T,
    encode: fn(state: T) -> Result[bytes.Bytes, mp.Error],
) -> Result[bool, mp.Error]:
    if not sync.should_emit(tick):
        return Result[bool, mp.Error].success(value = false)

    match encode(state):
        Result.failure as encode_error:
            return Result[bool, mp.Error].failure(error = encode_error.error)
        Result.success as encoded:
            var payload = encoded.value
            defer payload.release()

            match read(server).broadcast_snapshot(
                sync.descriptor.sync_channel,
                sync.descriptor.sync_mode,
                sync.snapshot_header(tick),
                payload.as_span(),
            ):
                Result.failure as send_error:
                    return Result[bool, mp.Error].failure(error = send_error.error)
                Result.success as sent:
                    if sent.value:
                        read(server).flush()

                    return Result[bool, mp.Error].success(value = sent.value)


public function drain_observer_state[T](
    sync: ObserverStateSync[T],
    client: ref[mp_enet.Client],
    state: ref[T],
    decode: fn(payload: span[ubyte], state: ref[T]) -> Result[bool, mp.Error],
) -> Result[ptr_uint, mp.Error]:
    var processed: ptr_uint = 0
    while true:
        var received = read(client).pop_snapshot() else:
            return Result[ptr_uint, mp.Error].success(value = processed)
        defer received.release()

        match decode(received.payload.as_span(), state):
            Result.failure as decode_error:
                return Result[ptr_uint, mp.Error].failure(error = decode_error.error)
            Result.success as decoded:
                if not decoded.value:
                    return Result[ptr_uint, mp.Error].failure(error = mp.error(
                        mp.ErrorCode.invalid_argument,
                        "snapshot payload was rejected by observer state codec"
                    ))
                processed += 1


function previous_tick(tick: mp.Tick) -> mp.Tick:
    if tick > 0:
        return tick - 1

    return 0
