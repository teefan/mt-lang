import std.bytes as bytes
import std.multiplayer as mp
import std.multiplayer.rpc as rpc_runtime
import std.multiplayer.wire as wire
import std.vec as vec

const net_channel_attr: ubyte = 0
const snapshot_payload_bytes: ptr_uint = 29
const submit_input_payload_bytes: ptr_uint = 9
const ball_dir_x_positive_flag: uint = 1
const ball_dir_y_positive_flag: uint = 2

public struct SubmitInputFrame:
    tick: mp.Tick
    input_flags: ubyte

@[mp.replicated(authority = mp.Authority.server)]
@[mp.sync_defaults(
    mode = mp.TransferMode.unreliable_ordered,
    channel = net_channel_attr,
    rate_hz = 30,
    target = mp.SyncTarget.observers,
)]
public struct PongNetState:
    @[mp.sync]
    phase: ubyte
    @[mp.sync]
    ball_x: int
    @[mp.sync]
    ball_y: int
    @[mp.sync]
    paddle_host_y: int
    @[mp.sync]
    paddle_join_y: int
    @[mp.sync]
    score_host: int
    @[mp.sync]
    score_join: int
    @[mp.sync]
    ball_dir_x_positive: bool
    @[mp.sync]
    ball_dir_y_positive: bool

var pending_submit_input: Option[SubmitInputFrame] = Option[SubmitInputFrame].none


@[mp.rpc(
    direction = mp.RpcDirection.client_to_server,
    mode = mp.TransferMode.unreliable_ordered,
    channel = net_channel_attr,
    require_owner = false,
)]
function submit_pong_input(_context: mp.RpcContext, frame: SubmitInputFrame) -> void:
    pending_submit_input = Option[SubmitInputFrame].some(value = frame)


public function install_bindings(builder: ptr[mp.BindingsBuilder]) -> Result[ptr_uint, mp.Error]:
    return mp.install_state_and_typed_rpc[PongNetState](
        builder,
        state_descriptor(),
        submit_input_descriptor(),
        dispatch_submit_pong_input,
    )


public function state_descriptor() -> mp.StateDescriptor:
    return mp.state_descriptor[PongNetState]()


public function submit_input_descriptor() -> mp.RpcDescriptor:
    return mp.rpc_descriptor(callable_of(submit_pong_input))


public function encode_submit_input_payload(tick: mp.Tick, input_flags: ubyte) -> array[ubyte, 9]:
    let encoded_tick = wire.encode_u64_be(tick)
    return array[ubyte, 9](
        encoded_tick[0],
        encoded_tick[1],
        encoded_tick[2],
        encoded_tick[3],
        encoded_tick[4],
        encoded_tick[5],
        encoded_tick[6],
        encoded_tick[7],
        input_flags,
    )


public function encode_state_snapshot(state: PongNetState) -> Result[bytes.Bytes, mp.Error]:
    var output = vec.Vec[ubyte].with_capacity(snapshot_payload_bytes)
    defer output.release()

    var direction_flags: uint = 0
    if state.ball_dir_x_positive:
        direction_flags |= ball_dir_x_positive_flag
    if state.ball_dir_y_positive:
        direction_flags |= ball_dir_y_positive_flag

    output.push(state.phase)
    output.append_array(wire.encode_u32_be(uint<-state.ball_x))
    output.append_array(wire.encode_u32_be(uint<-state.ball_y))
    output.append_array(wire.encode_u32_be(uint<-state.paddle_host_y))
    output.append_array(wire.encode_u32_be(uint<-state.paddle_join_y))
    output.append_array(wire.encode_u32_be(uint<-state.score_host))
    output.append_array(wire.encode_u32_be(uint<-state.score_join))
    output.append_array(wire.encode_u32_be(direction_flags))

    return Result[bytes.Bytes, mp.Error].success(value = bytes.Bytes.copy(output.as_span()))


public function decode_state_snapshot(payload: span[ubyte], state: ref[PongNetState]) -> Result[bool, mp.Error]:
    if payload.len < snapshot_payload_bytes:
        return Result[bool, mp.Error].failure(error = mp.error(
            mp.ErrorCode.invalid_argument,
            "pong snapshot payload is truncated"
        ))

    state.phase = payload[0]
    state.ball_x = int<-wire.decode_u32_be(payload, 1)
    state.ball_y = int<-wire.decode_u32_be(payload, 5)
    state.paddle_host_y = int<-wire.decode_u32_be(payload, 9)
    state.paddle_join_y = int<-wire.decode_u32_be(payload, 13)
    state.score_host = int<-wire.decode_u32_be(payload, 17)
    state.score_join = int<-wire.decode_u32_be(payload, 21)

    let direction_flags = wire.decode_u32_be(payload, 25)
    state.ball_dir_x_positive = (direction_flags & ball_dir_x_positive_flag) != 0
    state.ball_dir_y_positive = (direction_flags & ball_dir_y_positive_flag) != 0
    return Result[bool, mp.Error].success(value = true)


public function consume_submit_input() -> Option[SubmitInputFrame]:
    match pending_submit_input:
        Option.some as payload:
            pending_submit_input = Option[SubmitInputFrame].none
            return Option[SubmitInputFrame].some(value = payload.value)
        Option.none:
            return Option[SubmitInputFrame].none


public function reset_runtime_state() -> void:
    pending_submit_input = Option[SubmitInputFrame].none


function dispatch_submit_pong_input(
    context: mp.RpcContext,
    payload: span[ubyte],
) -> Result[bool, mp.DispatchError]:
    match rpc_runtime.dispatch_typed_payload(
        callable_of(submit_pong_input),
        context,
        payload,
    ):
        Result.failure as dispatch_error:
            return Result[bool, mp.DispatchError].failure(
                error = mp.DispatchError(code = dispatch_error.error.code, message = dispatch_error.error.message),
            )
        Result.success as dispatch_result:
            return Result[bool, mp.DispatchError].success(value = dispatch_result.value)
