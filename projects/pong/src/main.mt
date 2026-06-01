import std.enet as enet
import std.multiplayer as mp
import std.multiplayer.enet as mp_enet
import std.multiplayer.rollback as rollback
import networking as pong_net
import session as pong_session
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
const default_port: ushort = 24567
const connect_timeout_frames: uint = 360
const join_prediction_history_frames: ptr_uint = 240
const host_slot_connection_id: mp.ConnectionId = 0xffffffffffffffff

public enum Scene: ubyte
    menu = 0
    lobby = 1
    game = 2

public enum NetMode: ubyte
    none = 0
    host = 1
    join = 2

public struct App:
    scene: Scene
    mode: NetMode
    bindings: mp.BindingsBuilder
    server: Option[mp_enet.Server]
    client: Option[mp_enet.Client]
    state: pong_net.PongNetState
    tick: ulong
    remote_seen: bool
    client_was_ready: bool
    lobby_slots: mp.SlotRoster
    join_wait_frames: uint
    disconnect_message: str
    join_host_input: str_buffer[128]
    join_port_input: str_buffer[8]
    join_host_edit_mode: bool
    join_port_edit_mode: bool
    public_ip_input: str_buffer[64]
    public_ip_message: str
    last_authoritative_tick: Option[mp.Tick]
    next_join_input_tick: mp.Tick
    last_applied_join_input_tick: Option[mp.Tick]
    join_input_history: rollback.History[ubyte]
    join_paddle_history: rollback.History[int]
    status_code: int


function main(args: span[str]) -> int:
    if has_arg(args, "--smoke"):
        return run_smoke_test()

    let bindings = mp.build_frozen_bindings_with(pong_net.install_bindings) else:
        fatal(c"pong multiplayer bindings registration failed")

    var app = App(
        scene = Scene.menu,
        mode = NetMode.none,
        bindings = bindings,
        server = Option[mp_enet.Server].none,
        client = Option[mp_enet.Client].none,
        state = default_state(),
        tick = 1,
        remote_seen = false,
        client_was_ready = false,
        lobby_slots = mp.SlotRoster.create(2),
        join_wait_frames = 0,
        disconnect_message = "",
        join_host_input = zero[str_buffer[128]],
        join_port_input = zero[str_buffer[8]],
        join_host_edit_mode = false,
        join_port_edit_mode = false,
        public_ip_input = zero[str_buffer[64]],
        public_ip_message = "Press Fetch Public IP to query internet-visible address.",
        last_authoritative_tick = Option[mp.Tick].none,
        next_join_input_tick = 1,
        last_applied_join_input_tick = Option[mp.Tick].none,
        join_input_history = rollback.History[ubyte].create(join_prediction_history_frames),
        join_paddle_history = rollback.History[int].create(join_prediction_history_frames),
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
        if args[index] == wanted:
            return true
        index += 1

    return false


function release_app(app: ref[App]) -> void:
    shutdown_network(app)
    app.lobby_slots.release()
    app.join_input_history.release()
    app.join_paddle_history.release()
    app.bindings.release()


function default_state() -> pong_net.PongNetState:
    return pong_net.PongNetState(
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


function reset_round(state: ref[pong_net.PongNetState], toward_join: bool) -> void:
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
    app.lobby_slots.clear()
    app.join_wait_frames = 0
    app.last_authoritative_tick = Option[mp.Tick].none
    app.next_join_input_tick = 1
    app.last_applied_join_input_tick = Option[mp.Tick].none
    app.join_input_history.clear()
    app.join_paddle_history.clear()
    pong_net.reset_runtime_state()


function host_start(app: ref[App]) -> bool:
    shutdown_network(app)
    app.state = default_state()
    app.state.phase = 0

    let bind_address = enet.Address(
        host = uint<-enet.HOST_ANY,
        port = default_port
    )

    var server = mp_enet.listen(bind_address, 8, 2, app.bindings.registry, mp.default_config()) else:
        app.status_code = 2
        return false

    if not initialize_host_lobby_slots(app):
        server.release()
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
    if sanitized_public_ip.as_str() == trimmed_public_ip:
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

    let client = mp_enet.connect(remote_address, 2, app.bindings.registry, mp.default_config()) else:
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

    sync_host_lobby_slots(app, runtime)

    app.remote_seen = runtime.verified_peer_count() > 0
    if app.remote_seen:
        if app.state.phase == 0:
            var ready_to_start = false
            match app.lobby_slots.can_start_transition(2):
                Result.success as ready_payload:
                    ready_to_start = ready_payload.value
                Result.failure:
                    app.status_code = 48
                    app.disconnect_message = "failed to evaluate lobby readiness"
            if ready_to_start:
                app.disconnect_message = "Remote input detected. Host can start the match."
            else:
                app.disconnect_message = "Remote connected; waiting for first input."
        else:
            app.disconnect_message = ""
    if not app.remote_seen and app.state.phase == 1:
        app.state.phase = 0
        app.scene = Scene.lobby
        app.disconnect_message = "Remote player disconnected."
    if not app.remote_seen and app.state.phase == 0:
        app.disconnect_message = "Waiting for verified player..."

    while runtime.pending_rpc_count() > 0:
        var received = runtime.pop_rpc() else:
            app.status_code = 15
            app.server = Option[mp_enet.Server].some(value = runtime)
            return
        defer received.release()

        match app.bindings.typed_rpcs.dispatch_packet(received.context, received.header, received.payload.as_span()):
            Result.failure as dispatch_failure:
                app.disconnect_message = dispatch_failure.error.message
            Result.success as dispatch_result:
                if not dispatch_result.value:
                    app.disconnect_message = "submit_pong_input route declined inbound packet"
                    continue

                match pong_net.consume_submit_input():
                    Option.some as payload:
                        if app.state.phase == 0:
                            match received.context.sender:
                                Option.some as sender:
                                    match app.lobby_slots.set_ready(sender.value, true):
                                        Result.success:
                                            pass
                                        Result.failure:
                                            app.status_code = 41
                                            app.disconnect_message = "failed to update remote lobby readiness"
                                Option.none:
                                    pass
                        if should_apply_join_input(app, payload.value.tick):
                            apply_join_input(ref_of(app.state), payload.value.input_flags)
                            app.last_applied_join_input_tick = Option[mp.Tick].some(value = payload.value.tick)
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

    let drained = pong_session.drain_state_snapshots_with_info(ref_of(runtime), ref_of(app.state)) else as drain_error:
        app.status_code = 16
        app.disconnect_message = drain_error.message
        app.client = Option[mp_enet.Client].some(value = runtime)
        return

    match drained.latest_tick:
        Option.some as authoritative_tick:
            app.last_authoritative_tick = Option[mp.Tick].some(value = authoritative_tick.value)
            if app.next_join_input_tick <= authoritative_tick.value:
                app.next_join_input_tick = authoritative_tick.value + 1
            reconcile_join_prediction(app, authoritative_tick.value)
        Option.none:
            pass

    if app.state.phase == 1:
        app.scene = Scene.game

    app.client = Option[mp_enet.Client].some(value = runtime)


function host_broadcast_snapshot(app: ref[App]) -> void:
    let server = app.server else:
        return

    var runtime = server
    let snapshot_tick = app.tick
    app.tick += 1

    match pong_session.broadcast_state_snapshot(ref_of(runtime), snapshot_tick, app.state):
        Result.failure:
            app.status_code = 7
        Result.success:
            pass

    app.server = Option[mp_enet.Server].some(value = runtime)


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

    let input_tick = app.next_join_input_tick
    var payload = pong_net.encode_submit_input_payload(input_tick, input_flags)
    let payload_span = span[ubyte](data = ptr_of(payload[0]), len = 9)
    match runtime.send_rpc(
        pong_net.submit_input_descriptor().channel,
        pong_net.submit_input_descriptor().mode,
        pong_net.submit_input_descriptor().direction,
        payload_span
    ):
        Result.failure:
            app.status_code = 8
        Result.success:
            runtime.flush()
            if app.state.phase == 1:
                apply_join_input(ref_of(app.state), input_flags)
                if not record_join_prediction(app, input_tick, input_flags):
                    app.client = Option[mp_enet.Client].some(value = runtime)
                    return
            app.next_join_input_tick = input_tick + 1

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


function apply_join_input(state: ref[pong_net.PongNetState], input_flags: ubyte) -> void:
    if state.phase != 1:
        return

    if (input_flags & 1) != 0:
        state.paddle_join_y -= paddle_speed
    if (input_flags & 2) != 0:
        state.paddle_join_y += paddle_speed

    clamp_paddles(state)


function clamp_paddles(state: ref[pong_net.PongNetState]) -> void:
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


function clamp_paddle_y(value: int) -> int:
    let min_y = arena_top
    let max_y = arena_top + arena_height - paddle_height

    if value < min_y:
        return min_y
    if value > max_y:
        return max_y
    return value


function predict_join_paddle_y(paddle_y: int, input_flags: ubyte) -> int:
    var next = paddle_y
    if (input_flags & 1) != 0:
        next -= paddle_speed
    if (input_flags & 2) != 0:
        next += paddle_speed
    return clamp_paddle_y(next)


function record_join_prediction(app: ref[App], input_tick: mp.Tick, input_flags: ubyte) -> bool:
    let _ = app.join_input_history.record(input_tick, input_flags) else:
        app.status_code = 33
        app.disconnect_message = "failed to record predicted client input history"
        return false

    let _ = app.join_paddle_history.record(input_tick, app.state.paddle_join_y) else:
        app.status_code = 34
        app.disconnect_message = "failed to record predicted client paddle history"
        return false

    return true


function reconcile_join_prediction(app: ref[App], authoritative_tick: mp.Tick) -> void:
    if app.state.phase != 1:
        app.join_input_history.clear()
        app.join_paddle_history.clear()
        return

    let _ = rollback.reconcile_authoritative(
        ref_of(app.join_paddle_history),
        ref_of(app.join_input_history),
        authoritative_tick,
        app.state.paddle_join_y,
        predict_join_paddle_y,
    ) else:
        app.status_code = 36
        app.disconnect_message = "failed to reconcile predicted join paddle state"
        return

    match app.join_paddle_history.latest():
        Option.some as payload:
            if payload.value.tick > authoritative_tick:
                app.state.paddle_join_y = payload.value.value
        Option.none:
            pass


function should_apply_join_input(app: ref[App], input_tick: mp.Tick) -> bool:
    match app.last_applied_join_input_tick:
        Option.some as payload:
            return input_tick > payload.value
        Option.none:
            return true


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
        var can_start_match = false
        match read(app).lobby_slots.can_start_transition(2):
            Result.success as ready_payload:
                can_start_match = ready_payload.value
            Result.failure:
                pass
        if can_start_match:
            rl.draw_text("Remote input detected; ready to start", 60, 190, 24, rl.LIME)
        else if read(app).remote_seen:
            rl.draw_text("Remote connected; waiting for first input...", 60, 190, 24, rl.ORANGE)
        else:
            rl.draw_text("Waiting for verified player...", 60, 190, 24, rl.ORANGE)

        if gui.button(rl.Rectangle(x = 60.0, y = 250.0, width = 250.0, height = 40.0), "Start Match") != 0:
            start_host_match(app)

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

    if read(app).disconnect_message != "":
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


function initialize_host_lobby_slots(app: ref[App]) -> bool:
    app.lobby_slots.clear()

    let claimed = app.lobby_slots.claim_slot(host_slot_connection_id, 0) else:
        app.status_code = 42
        app.disconnect_message = "failed to initialize host lobby slot"
        return false
    if not claimed:
        app.status_code = 43
        app.disconnect_message = "host lobby slot was already occupied"
        return false

    let host_ready = app.lobby_slots.set_ready(host_slot_connection_id, true) else:
        app.status_code = 44
        app.disconnect_message = "failed to arm host lobby readiness"
        return false
    if not host_ready:
        app.status_code = 45
        app.disconnect_message = "host lobby readiness was not updated"
        return false

    return true


function sync_host_lobby_slots(app: ref[App], runtime: mp_enet.Server) -> void:
    if app.state.phase != 0:
        return

    if not app.lobby_slots.has_connection(host_slot_connection_id):
        if not initialize_host_lobby_slots(app):
            return

    match runtime.first_verified_connection():
        Option.some as payload:
            let remote_connection = payload.value
            match app.lobby_slots.slot(1):
                Option.some as slot_payload:
                    match slot_payload.value.connection:
                        Option.some as connection_payload:
                            if connection_payload.value != remote_connection:
                                let released = app.lobby_slots.release_connection(connection_payload.value)
                                if not released:
                                    app.status_code = 49
                                    app.disconnect_message = "failed to release stale remote lobby slot"
                                    return
                        Option.none:
                            pass
                Option.none:
                    pass

            match app.lobby_slots.claim_slot(remote_connection, 1):
                Result.success:
                    pass
                Result.failure:
                    app.status_code = 46
                    app.disconnect_message = "failed to claim remote lobby slot"
        Option.none:
            match app.lobby_slots.slot(1):
                Option.some as slot_payload:
                    match slot_payload.value.connection:
                        Option.some as connection_payload:
                            let released = app.lobby_slots.release_connection(connection_payload.value)
                            if not released:
                                app.status_code = 50
                                app.disconnect_message = "failed to release remote lobby slot"
                        Option.none:
                            pass
                Option.none:
                    pass


function start_host_match(app: ref[App]) -> void:
    let started = app.lobby_slots.begin_transition(2) else:
        app.status_code = 47
        app.disconnect_message = "failed to validate lobby transition"
        return

    match started:
        Option.none:
            if app.remote_seen:
                app.disconnect_message = "Waiting for join player input before starting."
            else:
                app.disconnect_message = "Waiting for verified player..."
            return
        Option.some:
            pass

    app.state.phase = 1
    app.scene = Scene.game
    app.state.score_host = 0
    app.state.score_join = 0
    app.state.paddle_host_y = arena_top + arena_height / 2 - paddle_height / 2
    app.state.paddle_join_y = arena_top + arena_height / 2 - paddle_height / 2
    reset_round(ref_of(app.state), true)
    host_broadcast_snapshot(app)


function run_smoke_test() -> int:
    let built_bindings = mp.build_frozen_bindings_with(pong_net.install_bindings) else:
        return 10
    var bindings = built_bindings
    defer bindings.release()

    var smoke_lobby = mp.SlotRoster.create(2)
    defer smoke_lobby.release()

    let host_claimed = smoke_lobby.claim_slot(host_slot_connection_id, 0) else:
        return 33
    if not host_claimed:
        return 34

    let host_ready = smoke_lobby.set_ready(host_slot_connection_id, true) else:
        return 35
    if not host_ready:
        return 36

    let address = enet.Address(
        host = uint<-enet.HOST_ANY,
        port = default_port
    )

    var server = mp_enet.listen(address, 2, 2, bindings.registry, mp.default_config()) else:
        return 11
    defer server.release()

    let remote = mp_enet.localhost_address(default_port) else:
        return 12

    var client = mp_enet.connect(remote, 2, bindings.registry, mp.default_config()) else:
        return 13
    defer client.release()

    var smoke_state = default_state()
    var remote_slot_claimed = false

    var rounds: ptr_uint = 0
    while rounds < 100:
        let _ = server.pump(1) else:
            return 14
        let _ = client.pump(1) else:
            return 15

        let sent = pong_session.broadcast_state_snapshot(ref_of(server), ulong<-rounds, default_state()) else:
            return 16
        if not sent:
            rounds += 1
            continue

        let _ = server.pump(1) else:
            return 18
        let _ = client.pump(1) else:
            return 19

        if client.protocol_ready():
            if not remote_slot_claimed:
                match server.first_verified_connection():
                    Option.some as verified_payload:
                        let claimed_remote = smoke_lobby.claim_slot(verified_payload.value, 1) else:
                            return 37
                        if not claimed_remote:
                            return 38
                        remote_slot_claimed = true
                    Option.none:
                        rounds += 1
                        continue

            let ready_before_input = smoke_lobby.can_start_transition(2) else:
                return 39
            if ready_before_input:
                return 40

            let drained = pong_session.drain_state_snapshots_with_info(ref_of(client), ref_of(smoke_state)) else:
                return 20
            if drained.processed > 0:
                let latest_tick = drained.latest_tick else:
                    return 21
                if latest_tick != ulong<-rounds:
                    return 22

                var input_payload = pong_net.encode_submit_input_payload(77, 1)
                let input_span = span[ubyte](data = ptr_of(input_payload[0]), len = 9)
                match client.send_rpc(
                    pong_net.submit_input_descriptor().channel,
                    pong_net.submit_input_descriptor().mode,
                    pong_net.submit_input_descriptor().direction,
                    input_span
                ):
                    Result.failure:
                        return 23
                    Result.success:
                        client.flush()

                let _ = server.pump(1) else:
                    return 24
                let _ = client.pump(1) else:
                    return 25

                var received = server.pop_rpc() else:
                    return 26
                defer received.release()

                match bindings.typed_rpcs.dispatch_packet(received.context, received.header, received.payload.as_span()):
                    Result.failure:
                        return 27
                    Result.success as dispatched:
                        if not dispatched.value:
                            return 28

                match received.context.sender:
                    Option.some as sender:
                        let remote_ready = smoke_lobby.set_ready(sender.value, true) else:
                            return 41
                        if not remote_ready:
                            return 42
                    Option.none:
                        return 43

                let ready_after_input = smoke_lobby.can_start_transition(2) else:
                    return 44
                if not ready_after_input:
                    return 45

                let started = smoke_lobby.begin_transition(2) else:
                    return 46
                match started:
                    Option.some as participant_payload:
                        if participant_payload.value != 2:
                            return 47
                    Option.none:
                        return 48

                let applied = pong_net.consume_submit_input() else:
                    return 29
                if applied.tick != 77:
                    return 30
                if applied.input_flags != 1:
                    return 31
                return 0

        rounds += 1

    return 32
