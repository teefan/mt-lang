import std.enet as enet
import std.multiplayer as mp
import std.multiplayer.enet as mp_enet
import std.multiplayer.rpc as rpc_runtime
import std.process as process
import std.raygui as gui
import std.raylib as rl
import std.string as string
import std.str as text
import std.vec as vec

const window_width: int = 960
const window_height: int = 540
const arena_left: int = 40
const arena_top: int = 70
const arena_width: int = 880
const arena_height: int = 430
const paddle_width: int = 16
const paddle_height: int = 96
const paddle_speed: int = 7
const ball_size: int = 14
const ball_speed_x: int = 4
const ball_speed_y: int = 3
const net_channel_attr: ubyte = 0
const local_snapshot_tick_hz: uint = 60
const default_port: ushort = 24567
const snapshot_payload_bytes: ptr_uint = 29
const connect_timeout_frames: uint = 360

public enum Scene: ubyte
    menu = 0
    lobby = 1
    game = 2

public enum NetMode: ubyte
    none = 0
    host = 1
    join = 2

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

public struct App:
    scene: Scene
    mode: NetMode
    registry: mp.Registry
    server: Option[mp_enet.Server]
    client: Option[mp_enet.Client]
    state: PongNetState
    tick: ulong
    remote_seen: bool
    client_was_ready: bool
    join_wait_frames: uint
    disconnect_message: str
    join_host_input: str_buffer[128]
    join_port_input: str_buffer[8]
    join_host_edit_mode: bool
    join_port_edit_mode: bool
    public_ip_input: str_buffer[64]
    public_ip_message: str
    state_descriptor: mp.StateDescriptor
    submit_input_descriptor: mp.RpcDescriptor
    status_code: int

var pending_submit_input: Option[ubyte] = Option[ubyte].none


@[mp.rpc(
    direction = mp.RpcDirection.client_to_server,
    mode = mp.TransferMode.unreliable_ordered,
    channel = net_channel_attr,
    require_owner = false,
)]
function submit_pong_input(_context: mp.RpcContext, input_flags: ubyte) -> void:
    pending_submit_input = Option[ubyte].some(value = input_flags)


function main(args: span[str]) -> int:
    if has_arg(args, "--smoke"):
        return run_smoke_test()

    let state_descriptor = mp.state_descriptor[PongNetState]()
    let submit_input_descriptor = mp.rpc_descriptor(callable_of(submit_pong_input))

    var app = App(
        scene = Scene.menu,
        mode = NetMode.none,
        registry = build_registry(),
        server = Option[mp_enet.Server].none,
        client = Option[mp_enet.Client].none,
        state = default_state(),
        tick = 1,
        remote_seen = false,
        client_was_ready = false,
        join_wait_frames = 0,
        disconnect_message = "",
        join_host_input = zero[str_buffer[128]],
        join_port_input = zero[str_buffer[8]],
        join_host_edit_mode = false,
        join_port_edit_mode = false,
        public_ip_input = zero[str_buffer[64]],
        public_ip_message = "Press Fetch Public IP to query internet-visible address.",
        state_descriptor = state_descriptor,
        submit_input_descriptor = submit_input_descriptor,
        status_code = 0
    )
    defer release_app(ref_of(app))

    app.join_host_input.assign("127.0.0.1")
    app.join_port_input.assign(f"#{default_port}")
    app.public_ip_input.assign("unknown")

    rl.init_window(window_width, window_height, "Milk Tea Multiplayer Pong")
    defer rl.close_window()
    rl.set_target_fps(60)
    gui.load_style_default()

    while not rl.window_should_close():
        update_app(ref_of(app))
        draw_app(ref_of(app))

    return app.status_code


function has_arg(args: span[str], wanted: str) -> bool:
    var index: ptr_uint = 0
    while index < args.len:
        if args[index].equal(wanted):
            return true
        index += 1

    return false


function build_registry() -> mp.Registry:
    var registry = mp.Registry.create()
    let state_desc = mp.state_descriptor[PongNetState]()
    let rpc_desc = mp.rpc_descriptor(callable_of(submit_pong_input))

    let state_added = registry.add_state(state_desc) else:
        fatal(c"pong registry state descriptor registration failed")

    if not state_added:
        fatal(c"pong registry state descriptor registration returned false")

    let rpc_added = registry.add_rpc(rpc_desc) else:
        fatal(c"pong registry rpc descriptor registration failed")

    if not rpc_added:
        fatal(c"pong registry rpc descriptor registration returned false")

    registry.freeze()
    return registry


function release_app(app: ref[App]) -> void:
    shutdown_network(app)
    app.registry.release()


function default_state() -> PongNetState:
    return PongNetState(
        phase = 0,
        ball_x = arena_left + arena_width / 2 - ball_size / 2,
        ball_y = arena_top + arena_height / 2 - ball_size / 2,
        paddle_host_y = arena_top + arena_height / 2 - paddle_height / 2,
        paddle_join_y = arena_top + arena_height / 2 - paddle_height / 2,
        score_host = 0,
        score_join = 0,
        ball_dir_x_positive = true,
        ball_dir_y_positive = true
    )


function reset_round(state: ref[PongNetState], toward_join: bool) -> void:
    state.ball_x = arena_left + arena_width / 2 - ball_size / 2
    state.ball_y = arena_top + arena_height / 2 - ball_size / 2
    state.ball_dir_x_positive = toward_join
    state.ball_dir_y_positive = true


function shutdown_network(app: ref[App]) -> void:
    match app.server:
        Option.some as payload:
            var owned_server = payload.value
            owned_server.release()
            app.server = Option[mp_enet.Server].none
        Option.none:
            pass

    match app.client:
        Option.some as payload:
            var owned_client = payload.value
            owned_client.release()
            app.client = Option[mp_enet.Client].none
        Option.none:
            pass

    app.mode = NetMode.none
    app.remote_seen = false
    app.client_was_ready = false
    app.join_wait_frames = 0
    pending_submit_input = Option[ubyte].none


function host_start(app: ref[App]) -> bool:
    shutdown_network(app)
    app.state = default_state()
    app.state.phase = 0

    let bind_address = enet.Address(
        host = uint<-enet.HOST_ANY,
        port = default_port
    )

    let server = mp_enet.listen(bind_address, 8, 2, app.registry, mp.default_config()) else:
        app.status_code = 2
        return false

    app.server = Option[mp_enet.Server].some(value = server)
    app.mode = NetMode.host
    app.scene = Scene.lobby
    app.remote_seen = false
    app.join_wait_frames = 0
    app.disconnect_message = ""
    app.public_ip_message = "Share your public IP and port with joiners."
    return true


function parse_port_text(value: str) -> Option[ushort]:
    let trimmed = value.trim_ascii_whitespace()
    if trimmed.len == 0:
        return Option[ushort].none

    var parsed: uint = 0
    var index: ptr_uint = 0
    while index < trimmed.len:
        let current = trimmed.byte_at(index)
        if current < 48 or current > 57:
            return Option[ushort].none

        parsed = parsed * 10 + uint<-(current - 48)
        if parsed > 65535:
            return Option[ushort].none
        index += 1

    if parsed == 0:
        return Option[ushort].none

    return Option[ushort].some(value = ushort<-parsed)


function lookup_public_ip() -> Result[string.String, string.String]:
    var command = vec.Vec[str].create()
    defer command.release()
    command.push("/bin/sh")
    command.push("-c")
    command.push("curl -fsS --max-time 4 https://api.ipify.org")

    match process.capture(command.as_span()):
        Result.failure as payload:
            var owned_error = payload.error
            defer owned_error.release()
            let message = string.String.from_str(f"failed to run curl: #{owned_error.message.as_str()}")
            return Result[string.String, string.String].failure(error = message)
        Result.success as payload:
            var result = payload.value
            defer result.release()

            if not result.status.success():
                let stderr_text = result.stderr_text() else:
                    let error_message = string.String.from_str("curl failed")
                    return Result[string.String, string.String].failure(error = error_message)
                let stderr_trimmed = stderr_text.trim_ascii_whitespace()
                return Result[string.String, string.String].failure(error = string.String.from_str(stderr_trimmed))

            let stdout_text = result.stdout_text() else:
                let error_message = string.String.from_str("curl returned non-utf8 output")
                return Result[string.String, string.String].failure(error = error_message)

            let trimmed = stdout_text.trim_ascii_whitespace()
            if trimmed.len == 0:
                let error_message = string.String.from_str("empty response from ip service")
                return Result[string.String, string.String].failure(error = error_message)

            return Result[string.String, string.String].success(value = string.String.from_str(trimmed))


function sanitize_public_ip_for_ui(raw: str) -> string.String:
    let trimmed = raw.trim_ascii_whitespace()
    var sanitized = string.String.with_capacity(trimmed.len)

    var index: ptr_uint = 0
    while index < trimmed.len:
        let current = trimmed.byte_at(index)
        if public_ip_ascii_allowed(current):
            sanitized.push_byte(current)
        index += 1

    if sanitized.len() == 0:
        sanitized.assign("unknown")

    return sanitized


function release_owned_string(value: string.String) -> void:
    var owned = value
    owned.release()


function public_ip_ascii_allowed(value: ubyte) -> bool:
    if value >= 48 and value <= 57:
        return true
    if value >= 65 and value <= 70:
        return true
    if value >= 97 and value <= 102:
        return true
    if value == 46 or value == 58 or value == 45 or value == 91 or value == 93 or value == 37:
        return true

    return false


function fetch_public_ip_into_app(app: ref[App]) -> void:
    let public_ip = lookup_public_ip() else as lookup_error:
        var owned_lookup_error = lookup_error
        defer owned_lookup_error.release()
        read(app).public_ip_message = "Public IP lookup failed."
        read(app).public_ip_input.assign("unknown")
        return

    defer release_owned_string(public_ip)
    let trimmed_public_ip = public_ip.as_str().trim_ascii_whitespace()
    var sanitized_public_ip = sanitize_public_ip_for_ui(trimmed_public_ip)
    defer sanitized_public_ip.release()
    read(app).public_ip_input.assign(sanitized_public_ip.as_str())
    if sanitized_public_ip.as_str().equal(trimmed_public_ip):
        read(app).public_ip_message = "Share this IP with joiners. Router must forward UDP port."
    else:
        read(app).public_ip_message = "Public IP sanitized for display. Copy and verify before sharing."


function join_start(app: ref[App]) -> bool:
    shutdown_network(app)
    app.state = default_state()
    app.state.phase = 0

    let host_text = app.join_host_input.as_str().trim_ascii_whitespace()
    if host_text.len == 0:
        app.status_code = 30
        app.disconnect_message = "Join host cannot be empty."
        return false

    let parsed_port = parse_port_text(app.join_port_input.as_str()) else:
        app.status_code = 31
        app.disconnect_message = "Join port must be 1-65535."
        return false

    var remote_address = enet.Address(
        host = uint<-enet.HOST_ANY,
        port = parsed_port
    )
    if enet.address_set_host_ip(ptr_of(remote_address), host_text) != 0:
        app.status_code = 3
        app.disconnect_message = "Invalid host address format."
        return false

    let client = mp_enet.connect(remote_address, 2, app.registry, mp.default_config()) else:
        app.status_code = 4
        return false

    app.client = Option[mp_enet.Client].some(value = client)
    app.mode = NetMode.join
    app.scene = Scene.lobby
    app.remote_seen = false
    app.client_was_ready = false
    app.join_wait_frames = 0
    app.disconnect_message = f"Connecting to #{host_text}:#{parsed_port}..."
    return true


function update_app(app: ref[App]) -> void:
    match app.scene:
        Scene.menu:
            update_menu(app)
        Scene.lobby:
            update_lobby(app)
        Scene.game:
            update_game(app)


function update_menu(app: ref[App]) -> void:
    if rl.is_key_pressed(rl.KeyboardKey.KEY_ESCAPE):
        app.status_code = 0
        return


function update_lobby(app: ref[App]) -> void:
    if app.mode == NetMode.host:
        update_host_network(app)
    if app.mode == NetMode.join:
        update_join_network(app)

    if rl.is_key_pressed(rl.KeyboardKey.KEY_ESCAPE):
        shutdown_network(app)
        app.scene = Scene.menu


function update_game(app: ref[App]) -> void:
    if app.mode == NetMode.host:
        update_host_network(app)
        update_host_simulation(app)
        host_broadcast_snapshot(app)

    if app.mode == NetMode.join:
        update_join_network(app)
        join_send_input(app)

    if rl.is_key_pressed(rl.KeyboardKey.KEY_ESCAPE):
        app.scene = Scene.lobby
        if app.mode == NetMode.host:
            app.state.phase = 0
            host_broadcast_snapshot(app)


function update_host_network(app: ref[App]) -> void:
    var runtime = app.server else:
        return
    let _ = runtime.pump(0) else:
        app.status_code = 5
        app.server = Option[mp_enet.Server].some(value = runtime)
        return

    while runtime.pending_session_event_count() > 0:
        let session_event_option = runtime.pop_session_event()
        var session_event = mp_enet.SessionEventRecord(
            kind = mp_enet.SessionEvent.connected,
            connection = Option[mp.ConnectionId].none
        )
        match session_event_option:
            Option.none:
                break
            Option.some as payload:
                session_event = payload.value

        match session_event.kind:
            mp_enet.SessionEvent.connected:
                app.disconnect_message = "Player connected; waiting for protocol verification."
            mp_enet.SessionEvent.disconnected:
                app.disconnect_message = "Player disconnected from host."
            mp_enet.SessionEvent.snapshot_received:
                pass
            mp_enet.SessionEvent.rpc_received:
                pass

    app.remote_seen = runtime.verified_peer_count() > 0
    if app.remote_seen:
        app.disconnect_message = ""
    if not app.remote_seen and app.state.phase == 1:
        app.state.phase = 0
        app.scene = Scene.lobby
        app.disconnect_message = "Remote player disconnected."

    while runtime.pending_rpc_count() > 0:
        var received = runtime.pop_rpc() else:
            app.status_code = 15
            app.server = Option[mp_enet.Server].some(value = runtime)
            return
        defer received.release()

        if received.header.channel != app.submit_input_descriptor.channel:
            app.disconnect_message = "submit_pong_input channel mismatch"
            continue

        if received.header.direction != app.submit_input_descriptor.direction:
            app.disconnect_message = "submit_pong_input direction mismatch"
            continue

        let bytes = received.payload.as_span()
        match rpc_runtime.dispatch_typed_payload(callable_of(submit_pong_input), received.context, bytes):
            Result.failure as dispatch_failure:
                app.disconnect_message = dispatch_failure.error.message
            Result.success:
                match pending_submit_input:
                    Option.some as payload:
                        apply_join_input(ref_of(app.state), payload.value)
                        pending_submit_input = Option[ubyte].none
                    Option.none:
                        app.disconnect_message = "submit_pong_input did not provide decoded payload"

    app.server = Option[mp_enet.Server].some(value = runtime)


function update_join_network(app: ref[App]) -> void:
    var runtime = app.client else:
        return
    let _ = runtime.pump(0) else:
        app.status_code = 6
        app.disconnect_message = "Connection failed while polling network events."
        app.client = Option[mp_enet.Client].some(value = runtime)
        return

    let connected_now = runtime.is_connected()
    let ready_now = runtime.protocol_ready()

    while runtime.pending_session_event_count() > 0:
        let session_event_option = runtime.pop_session_event()
        var session_event = mp_enet.SessionEventRecord(
            kind = mp_enet.SessionEvent.connected,
            connection = Option[mp.ConnectionId].none
        )
        match session_event_option:
            Option.none:
                break
            Option.some as payload:
                session_event = payload.value

        match session_event.kind:
            mp_enet.SessionEvent.connected:
                app.disconnect_message = "Transport connected; waiting for handshake..."
            mp_enet.SessionEvent.disconnected:
                app.disconnect_message = "Disconnected from host."
            mp_enet.SessionEvent.snapshot_received:
                pass
            mp_enet.SessionEvent.rpc_received:
                pass

    if runtime.pending_unknown_count() > 0 and not ready_now:
        app.disconnect_message = "Handshake/protocol mismatch. Ensure both sides use same build."

    if not ready_now:
        app.join_wait_frames += 1
    else:
        app.join_wait_frames = 0

    if app.join_wait_frames > connect_timeout_frames and not ready_now:
        app.disconnect_message = "No host response. Check IP, UDP port forwarding, firewall, and NAT."

    if app.client_was_ready and (not connected_now or not ready_now):
        app.state.phase = 0
        app.scene = Scene.lobby
        app.disconnect_message = "Disconnected from host."
    if ready_now:
        app.disconnect_message = ""
    app.client_was_ready = ready_now

    while runtime.pending_snapshot_count() > 0:
        var received = runtime.pop_snapshot() else:
            app.status_code = 16
            app.client = Option[mp_enet.Client].some(value = runtime)
            return
        defer received.release()

        let bytes = received.payload.as_span()
        decode_snapshot_payload(bytes, ref_of(app.state))

    if app.state.phase == 1:
        app.scene = Scene.game

    app.client = Option[mp_enet.Client].some(value = runtime)


function host_broadcast_snapshot(app: ref[App]) -> void:
    let server = app.server else:
        return

    var runtime = server
    let descriptor = app.state_descriptor
    let snapshot_tick = app.tick
    app.tick += 1

    if not should_emit_observer_snapshot(descriptor, snapshot_tick):
        app.server = Option[mp_enet.Server].some(value = runtime)
        return

    var payload = encode_snapshot_payload(app.state)
    let payload_span = span[ubyte](data = ptr_of(payload[0]), len = snapshot_payload_bytes)
    let header = mp.SnapshotPacketHeader(
        tick = snapshot_tick,
        baseline_tick = previous_tick(snapshot_tick),
        entity_count = 1
    )

    let send_result = runtime.broadcast_snapshot(descriptor.sync_channel, descriptor.sync_mode, header, payload_span)
    match send_result:
        Result.failure:
            app.status_code = 7
        Result.success:
            runtime.flush()

    app.server = Option[mp_enet.Server].some(value = runtime)


function previous_tick(tick: ulong) -> ulong:
    if tick > 0:
        return tick - 1

    return 0


function should_emit_observer_snapshot(descriptor: mp.StateDescriptor, tick: ulong) -> bool:
    if descriptor.sync_field_count == 0:
        return false

    if descriptor.sync_target != mp.SyncTarget.observers:
        return false

    if descriptor.sync_rate_hz == 0:
        return false

    if descriptor.sync_rate_hz >= local_snapshot_tick_hz:
        return true

    let stride_hz = local_snapshot_tick_hz / descriptor.sync_rate_hz
    if stride_hz == 0:
        return true

    return tick % ulong<-stride_hz == 0


function join_send_input(app: ref[App]) -> void:
    let client = app.client else:
        return

    let runtime = client
    if not runtime.protocol_ready():
        app.client = Option[mp_enet.Client].some(value = runtime)
        return

    var input_flags: ubyte = 0
    if rl.is_key_down(rl.KeyboardKey.KEY_UP):
        input_flags |= 1
    if rl.is_key_down(rl.KeyboardKey.KEY_DOWN):
        input_flags |= 2

    var payload = array[ubyte, 1](input_flags)
    let payload_span = span[ubyte](data = ptr_of(payload[0]), len = 1)
    let send_result = runtime.send_rpc(
        app.submit_input_descriptor.channel,
        app.submit_input_descriptor.mode,
        app.submit_input_descriptor.direction,
        payload_span
    )
    match send_result:
        Result.failure:
            app.status_code = 8
        Result.success:
            runtime.flush()

    app.client = Option[mp_enet.Client].some(value = runtime)


function update_host_simulation(app: ref[App]) -> void:
    if app.state.phase != 1:
        return

    if rl.is_key_down(rl.KeyboardKey.KEY_W):
        app.state.paddle_host_y -= paddle_speed
    if rl.is_key_down(rl.KeyboardKey.KEY_S):
        app.state.paddle_host_y += paddle_speed

    clamp_paddles(ref_of(app.state))

    if app.state.ball_dir_x_positive:
        app.state.ball_x += ball_speed_x
    else:
        app.state.ball_x -= ball_speed_x

    if app.state.ball_dir_y_positive:
        app.state.ball_y += ball_speed_y
    else:
        app.state.ball_y -= ball_speed_y

    if app.state.ball_y <= arena_top:
        app.state.ball_y = arena_top
        app.state.ball_dir_y_positive = true

    if app.state.ball_y + ball_size >= arena_top + arena_height:
        app.state.ball_y = arena_top + arena_height - ball_size
        app.state.ball_dir_y_positive = false

    let host_x = arena_left + 12
    let join_x = arena_left + arena_width - 12 - paddle_width

    if intersects(
        app.state.ball_x,
        app.state.ball_y,
        ball_size,
        ball_size,
        host_x,
        app.state.paddle_host_y,
        paddle_width,
        paddle_height
    ):
        app.state.ball_x = host_x + paddle_width
        app.state.ball_dir_x_positive = true

    if intersects(
        app.state.ball_x,
        app.state.ball_y,
        ball_size,
        ball_size,
        join_x,
        app.state.paddle_join_y,
        paddle_width,
        paddle_height
    ):
        app.state.ball_x = join_x - ball_size
        app.state.ball_dir_x_positive = false

    if app.state.ball_x < arena_left:
        app.state.score_join += 1
        reset_round(ref_of(app.state), true)

    if app.state.ball_x > arena_left + arena_width - ball_size:
        app.state.score_host += 1
        reset_round(ref_of(app.state), false)


function apply_join_input(state: ref[PongNetState], input_flags: ubyte) -> void:
    if state.phase != 1:
        return

    if (input_flags & 1) != 0:
        state.paddle_join_y -= paddle_speed
    if (input_flags & 2) != 0:
        state.paddle_join_y += paddle_speed

    clamp_paddles(state)


function clamp_paddles(state: ref[PongNetState]) -> void:
    let min_y = arena_top
    let max_y = arena_top + arena_height - paddle_height

    if state.paddle_host_y < min_y:
        state.paddle_host_y = min_y
    if state.paddle_host_y > max_y:
        state.paddle_host_y = max_y

    if state.paddle_join_y < min_y:
        state.paddle_join_y = min_y
    if state.paddle_join_y > max_y:
        state.paddle_join_y = max_y


function intersects(ax: int, ay: int, aw: int, ah: int, bx: int, by: int, bw: int, bh: int) -> bool:
    if ax + aw <= bx:
        return false
    if bx + bw <= ax:
        return false
    if ay + ah <= by:
        return false
    if by + bh <= ay:
        return false
    return true


function encode_snapshot_payload(state: PongNetState) -> array[ubyte, 29]:
    var dir_flags: uint = 0
    if state.ball_dir_x_positive:
        dir_flags |= 1
    if state.ball_dir_y_positive:
        dir_flags |= 2

    let ball_x = encode_u32(uint<-state.ball_x)
    let ball_y = encode_u32(uint<-state.ball_y)
    let paddle_host = encode_u32(uint<-state.paddle_host_y)
    let paddle_join = encode_u32(uint<-state.paddle_join_y)
    let score_host = encode_u32(uint<-state.score_host)
    let score_join = encode_u32(uint<-state.score_join)
    let directions = encode_u32(dir_flags)

    return array[ubyte, 29](
        state.phase,
        ball_x[0],
        ball_x[1],
        ball_x[2],
        ball_x[3],
        ball_y[0],
        ball_y[1],
        ball_y[2],
        ball_y[3],
        paddle_host[0],
        paddle_host[1],
        paddle_host[2],
        paddle_host[3],
        paddle_join[0],
        paddle_join[1],
        paddle_join[2],
        paddle_join[3],
        score_host[0],
        score_host[1],
        score_host[2],
        score_host[3],
        score_join[0],
        score_join[1],
        score_join[2],
        score_join[3],
        directions[0],
        directions[1],
        directions[2],
        directions[3]
    )


function decode_snapshot_payload(payload: span[ubyte], state: ref[PongNetState]) -> bool:
    if payload.len < snapshot_payload_bytes:
        return false

    state.phase = payload[0]
    state.ball_x = int<-decode_u32(payload, 1)
    state.ball_y = int<-decode_u32(payload, 5)
    state.paddle_host_y = int<-decode_u32(payload, 9)
    state.paddle_join_y = int<-decode_u32(payload, 13)
    state.score_host = int<-decode_u32(payload, 17)
    state.score_join = int<-decode_u32(payload, 21)

    let dir_flags = decode_u32(payload, 25)
    state.ball_dir_x_positive = (dir_flags & 1) != 0
    state.ball_dir_y_positive = (dir_flags & 2) != 0
    return true


function encode_u32(value: uint) -> array[ubyte, 4]:
    return array[ubyte, 4](
        ubyte<-((value >> 24) & 255),
        ubyte<-((value >> 16) & 255),
        ubyte<-((value >> 8) & 255),
        ubyte<-(value & 255)
    )


function decode_u32(input: span[ubyte], offset: ptr_uint) -> uint:
    return (
        ((uint<-input[offset]) << 24)
        | ((uint<-input[offset + 1]) << 16)
        | ((uint<-input[offset + 2]) << 8)
        | (uint<-input[offset + 3])
    )


function draw_app(app: ref[App]) -> void:
    rl.begin_drawing()
    defer rl.end_drawing()

    rl.clear_background(rl.Color(r = 9, g = 14, b = 26, a = 255))

    match read(app).scene:
        Scene.menu:
            draw_menu(app)
        Scene.lobby:
            draw_lobby(app)
        Scene.game:
            draw_game(app)


function draw_menu(app: ref[App]) -> void:
    rl.draw_text("MILK TEA PONG", 320, 64, 50, rl.RAYWHITE)
    rl.draw_text("Multiplayer over std.multiplayer.enet", 274, 122, 20, rl.SKYBLUE)

    if gui.button(rl.Rectangle(x = 355.0, y = 190.0, width = 250.0, height = 42.0), "Host Game") != 0:
        let _ = host_start(app)

    rl.draw_text("Join Host", 355, 248, 20, rl.LIGHTGRAY)
    if gui.text_box(
        rl.Rectangle(x = 355.0, y = 272.0, width = 250.0, height = 34.0),
        read(app).join_host_input,
        read(app).join_host_edit_mode
    ) != 0:
        read(app).join_host_edit_mode = not read(app).join_host_edit_mode

    rl.draw_text("Join Port", 355, 314, 20, rl.LIGHTGRAY)
    if gui.text_box(
        rl.Rectangle(x = 355.0, y = 338.0, width = 250.0, height = 34.0),
        read(app).join_port_input,
        read(app).join_port_edit_mode
    ) != 0:
        read(app).join_port_edit_mode = not read(app).join_port_edit_mode

    if gui.button(rl.Rectangle(x = 355.0, y = 386.0, width = 250.0, height = 42.0), "Join Game") != 0:
        let _ = join_start(app)

    if gui.button(rl.Rectangle(x = 355.0, y = 436.0, width = 250.0, height = 42.0), "Quit") != 0:
        rl.close_window()

    rl.draw_text("Run two instances or join by public IP and forwarded UDP port.", 176, 502, 20, rl.LIGHTGRAY)


function draw_lobby(app: ref[App]) -> void:
    rl.draw_text("LOBBY", 424, 70, 48, rl.RAYWHITE)

    if read(app).mode == NetMode.host:
        rl.draw_text("Mode: HOST", 60, 150, 28, rl.GOLD)
        if read(app).remote_seen:
            rl.draw_text("Remote player detected", 60, 190, 24, rl.LIME)
        else:
            rl.draw_text("Waiting for verified player...", 60, 190, 24, rl.ORANGE)

        if gui.button(rl.Rectangle(x = 60.0, y = 250.0, width = 250.0, height = 40.0), "Start Match") != 0:
            if read(app).remote_seen:
                read(app).state.phase = 1
                read(app).scene = Scene.game
                read(app).state.score_host = 0
                read(app).state.score_join = 0
                read(app).state.paddle_host_y = arena_top + arena_height / 2 - paddle_height / 2
                read(app).state.paddle_join_y = arena_top + arena_height / 2 - paddle_height / 2
                reset_round(ref_of(read(app).state), true)
                host_broadcast_snapshot(app)

        if gui.button(rl.Rectangle(x = 340.0, y = 250.0, width = 190.0, height = 40.0), "Fetch Public IP") != 0:
            fetch_public_ip_into_app(app)

        if gui.button(rl.Rectangle(x = 544.0, y = 250.0, width = 150.0, height = 40.0), "Copy Public IP") != 0:
            rl.set_clipboard_text(read(app).public_ip_input.as_str())
            read(app).public_ip_message = "Public IP copied to clipboard."

        rl.draw_text("Public IP", 340, 310, 22, rl.LIGHTGRAY)
        let public_ip_bounds = rl.Rectangle(x = 340.0, y = 336.0, width = 354.0, height = 36.0)
        rl.draw_rectangle_rounded(public_ip_bounds, 0.12, 8, rl.Color(r = 24, g = 30, b = 44, a = 255))
        rl.draw_rectangle_rounded_lines_ex(public_ip_bounds, 0.12, 8, 1.0, rl.Color(r = 96, g = 108, b = 148, a = 255))
        rl.draw_text(read(app).public_ip_input.as_str(), 350, 345, 20, rl.RAYWHITE)
        rl.draw_text(read(app).public_ip_message, 340, 380, 20, rl.GRAY)

    if read(app).mode == NetMode.join:
        rl.draw_text("Mode: CLIENT", 60, 150, 28, rl.SKYBLUE)
        let client = read(app).client else:
            rl.draw_text("Client session unavailable", 60, 190, 24, rl.RED)
            return

        if client.protocol_ready():
            rl.draw_text("Connected and protocol-ready", 60, 190, 24, rl.LIME)
        else:
            rl.draw_text("Connecting to configured host...", 60, 190, 24, rl.ORANGE)

    if not read(app).disconnect_message.equal(""):
        rl.draw_text(read(app).disconnect_message, 60, 360, 22, rl.ORANGE)

    if gui.button(rl.Rectangle(x = 60.0, y = 310.0, width = 250.0, height = 40.0), "Back To Menu") != 0:
        shutdown_network(app)
        read(app).scene = Scene.menu

    rl.draw_text("Controls: Host uses W/S, Join uses Up/Down", 60, 412, 22, rl.LIGHTGRAY)
    rl.draw_text(
        "For internet play, host must forward UDP port and allow firewall traffic.",
        60,
        442,
        20,
        rl.GRAY
    )


function draw_game(app: ref[App]) -> void:
    rl.draw_text("PONG", 442, 18, 36, rl.RAYWHITE)
    rl.draw_rectangle_lines(
        arena_left,
        arena_top,
        arena_width,
        arena_height,
        rl.Color(r = 110, g = 128, b = 180, a = 255)
    )

    let center_x = arena_left + arena_width / 2
    var marker_y = arena_top
    while marker_y < arena_top + arena_height:
        rl.draw_rectangle(center_x - 2, marker_y, 4, 12, rl.Color(r = 80, g = 92, b = 140, a = 180))
        marker_y += 22

    let host_x = arena_left + 12
    let join_x = arena_left + arena_width - 12 - paddle_width
    rl.draw_rectangle(host_x, read(app).state.paddle_host_y, paddle_width, paddle_height, rl.LIME)
    rl.draw_rectangle(join_x, read(app).state.paddle_join_y, paddle_width, paddle_height, rl.SKYBLUE)
    rl.draw_rectangle(read(app).state.ball_x, read(app).state.ball_y, ball_size, ball_size, rl.RAYWHITE)

    rl.draw_text(f"#{read(app).state.score_host}", 350, 26, 34, rl.LIME)
    rl.draw_text(f"#{read(app).state.score_join}", 588, 26, 34, rl.SKYBLUE)

    if read(app).mode == NetMode.host:
        rl.draw_text("HOST", 64, 26, 24, rl.GOLD)
    if read(app).mode == NetMode.join:
        rl.draw_text("CLIENT", 64, 26, 24, rl.SKYBLUE)

    if read(app).state.phase == 0:
        rl.draw_text("Waiting for host to start...", 340, 470, 24, rl.ORANGE)


function run_smoke_test() -> int:
    var registry = build_registry()
    defer registry.release()
    let state_descriptor = mp.state_descriptor[PongNetState]()

    let address = enet.Address(
        host = uint<-enet.HOST_ANY,
        port = default_port
    )

    var server = mp_enet.listen(address, 2, 2, registry, mp.default_config()) else:
        return 11
    defer server.release()

    let remote = mp_enet.localhost_address(default_port) else:
        return 12

    var client = mp_enet.connect(remote, 2, registry, mp.default_config()) else:
        return 13
    defer client.release()

    var rounds: ptr_uint = 0
    while rounds < 100:
        let _ = server.pump(1) else:
            return 14
        let _ = client.pump(1) else:
            return 15

        var payload = encode_snapshot_payload(default_state())
        let payload_span = span[ubyte](data = ptr_of(payload[0]), len = snapshot_payload_bytes)
        let header = mp.SnapshotPacketHeader(tick = 1, baseline_tick = 0, entity_count = 1)
        let sent = server.broadcast_snapshot(
            state_descriptor.sync_channel,
            state_descriptor.sync_mode,
            header,
            payload_span
        ) else:
            return 16
        if not sent:
            return 17
        server.flush()

        let _ = server.pump(1) else:
            return 18
        let _ = client.pump(1) else:
            return 19

        if client.pending_snapshot_count() > 0 and client.protocol_ready():
            var received = client.pop_snapshot() else:
                return 20
            defer received.release()
            var smoke_state = default_state()
            let decoded = decode_snapshot_payload(received.payload.as_span(), ref_of(smoke_state))
            if not decoded:
                return 21
            return 0

        rounds += 1

    return 22
