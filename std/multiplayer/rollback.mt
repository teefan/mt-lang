import std.deque as deque
import std.multiplayer.protocol as protocol

public type Tick = protocol.Tick
public type Error = protocol.Error
public type ErrorCode = protocol.ErrorCode

public struct Frame[T]:
    tick: Tick
    value: T

public struct History[T]:
    frames: deque.Deque[Frame[T]]
    max_frames: ptr_uint


extending History[T]:
    public static function create(max_frames: ptr_uint) -> History[T]:
        return History[T](frames = deque.Deque[Frame[T]].create(), max_frames = max_frames)


    public function len() -> ptr_uint:
        return this.frames.len()


    public function max_frames() -> ptr_uint:
        return this.max_frames


    public function is_empty() -> bool:
        return this.frames.is_empty()


    public function oldest() -> Option[Frame[T]]:
        let oldest = this.frames.first() else:
            return Option[Frame[T]].none

        unsafe:
            return Option[Frame[T]].some(value = read(oldest))


    public function latest() -> Option[Frame[T]]:
        let latest = this.frames.last() else:
            return Option[Frame[T]].none

        unsafe:
            return Option[Frame[T]].some(value = read(latest))


    public function find(tick: Tick) -> Option[Frame[T]]:
        var index: ptr_uint = 0
        while index < this.frames.len():
            let frame = this.frames.get(index)
            if frame == null:
                break

            unsafe:
                let frame_ptr = ptr[Frame[T]]<-frame
                if read(frame_ptr).tick == tick:
                    return Option[Frame[T]].some(value = read(frame_ptr))

            index += 1

        return Option[Frame[T]].none


    public function frame_at(index: ptr_uint) -> Option[Frame[T]]:
        let frame = this.frames.get(index) else:
            return Option[Frame[T]].none

        unsafe:
            return Option[Frame[T]].some(value = read(frame))


    public mutable function record(tick: Tick, value: T) -> Result[bool, Error]:
        if this.max_frames == 0:
            return Result[bool, Error].failure(error = protocol.error(
                ErrorCode.invalid_argument,
                "rollback history requires max_frames > 0"
            ))

        let latest_ptr = this.frames.last()
        if latest_ptr != null:
            unsafe:
                let narrowed_latest = ptr[Frame[T]]<-latest_ptr
                let latest_frame = read(narrowed_latest)
                if tick < latest_frame.tick:
                    return Result[bool, Error].failure(error = protocol.error(
                        ErrorCode.invalid_argument,
                        "rollback history requires nondecreasing ticks; discard_after before rewriting older frames"
                    ))

                if tick == latest_frame.tick:
                    read(narrowed_latest) = Frame[T](tick = tick, value = value)
                    return Result[bool, Error].success(value = false)

        this.frames.push_back(Frame[T](tick = tick, value = value))
        trim_to_capacity(ref_of(this))
        return Result[bool, Error].success(value = true)


    public mutable function discard_before(first_tick_to_keep: Tick) -> ptr_uint:
        var removed: ptr_uint = 0
        while true:
            let oldest = this.frames.first() else:
                return removed

            unsafe:
                if read(oldest).tick >= first_tick_to_keep:
                    return removed

            match this.frames.pop_front():
                Option.some:
                    removed += 1
                Option.none:
                    return removed


    public mutable function discard_after(last_tick_to_keep: Tick) -> ptr_uint:
        var removed: ptr_uint = 0
        while true:
            let latest = this.frames.last() else:
                return removed

            unsafe:
                if read(latest).tick <= last_tick_to_keep:
                    return removed

            match this.frames.pop_back():
                Option.some:
                    removed += 1
                Option.none:
                    return removed


    public mutable function clear() -> void:
        this.frames.clear()


    public mutable function release() -> void:
        this.frames.release()
        this.max_frames = 0


function trim_to_capacity[T](history: ref[History[T]]) -> void:
    while read(history).frames.len() > read(history).max_frames:
        match read(history).frames.pop_front():
            Option.some:
                pass
            Option.none:
                return


public function resimulate_from[TState, TInput](
    states: ref[History[TState]],
    inputs: ref[History[TInput]],
    authoritative_tick: Tick,
    step: fn(state: TState, input: TInput) -> TState
) -> Result[ptr_uint, Error]:
    let base_state = read(states).find(authoritative_tick) else:
        return Result[ptr_uint, Error].failure(error = protocol.error(
            ErrorCode.invalid_argument,
            "rollback resimulation requires an authoritative base state at the requested tick"
        ))

    read(states).discard_after(authoritative_tick)

    var replayed: ptr_uint = 0
    var current_state = base_state.value
    var index: ptr_uint = 0
    while index < read(inputs).len():
        match read(inputs).frame_at(index):
            Option.some as payload:
                let input_frame = payload.value
                if input_frame.tick > authoritative_tick:
                    current_state = step(current_state, input_frame.value)
                    match read(states).record(input_frame.tick, current_state):
                        Result.success as _:
                            replayed += 1
                        Result.failure as record_result:
                            return Result[ptr_uint, Error].failure(error = record_result.error)
            Option.none:
                break

        index += 1

    return Result[ptr_uint, Error].success(value = replayed)


public function reconcile_authoritative[TState, TInput](
    states: ref[History[TState]],
    inputs: ref[History[TInput]],
    authoritative_tick: Tick,
    authoritative_state: TState,
    step: fn(state: TState, input: TInput) -> TState
) -> Result[ptr_uint, Error]:
    read(inputs).discard_before(authoritative_tick)
    read(states).discard_after(authoritative_tick)

    let _ = read(states).record(authoritative_tick, authoritative_state) else as record_error:
        return Result[ptr_uint, Error].failure(error = record_error)

    return resimulate_from(states, inputs, authoritative_tick, step)
