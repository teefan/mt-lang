import std.sdl3 as sdl

const MAP_BOX_SCALE: int = 16
const MAP_BOX_EDGES_LEN: int = 12 + MAP_BOX_SCALE * 2
const MAX_PLAYER_COUNT: int = 4
const CIRCLE_DRAW_SIDES: int = 32
const CIRCLE_DRAW_SIDES_LEN: int = CIRCLE_DRAW_SIDES + 1
const BIN_RAD: double = sdl.PI_D / 2147483648.0d
const EDGE_MAP: array[int, 24] = array[int, 24](
    0, 1, 1, 3, 3, 2, 2, 0,
    7, 6, 6, 4, 4, 5, 5, 7,
    6, 2, 3, 7, 0, 4, 5, 1
)

const WASD_FORWARD: ubyte = 1
const WASD_LEFT: ubyte = 2
const WASD_BACK: ubyte = 4
const WASD_RIGHT: ubyte = 8
const WASD_JUMP: ubyte = 16

struct Player:
    mouse: sdl.MouseID
    keyboard: sdl.KeyboardID
    pos: array[double, 3]
    vel: array[double, 3]
    yaw: uint
    pitch: int
    radius: float
    height: float
    color: array[ubyte, 3]
    wasd: ubyte

struct AppState:
    player_count: int
    players: array[Player, MAX_PLAYER_COUNT]
    edges: array[array[float, 6], MAP_BOX_EDGES_LEN]
    debug_string: str_buffer[32]


function fmax(a: double, b: double) -> double:
    return if a > b: a else: b


function fmin(a: double, b: double) -> double:
    return if a < b: a else: b


function imax(a: int, b: int) -> int:
    return if a > b: a else: b


function imin(a: int, b: int) -> int:
    return if a < b: a else: b


function wasd_axis(wasd: int, positive: int, negative: int) -> double:
    let pos = if (wasd & positive) != 0: 1.0d else: 0.0d
    let neg = if (wasd & negative) != 0: 1.0d else: 0.0d
    return pos - neg


struct Vec3:
    x: float
    y: float
    z: float


function rotate_point(mat: ref[array[double, 9]], px: double, py: double, pz: double) -> Vec3:
    var result: Vec3
    result.x = float<-(read(mat)[0] * px + read(mat)[1] * py + read(mat)[2] * pz)
    result.y = float<-(read(mat)[3] * px + read(mat)[4] * py + read(mat)[5] * pz)
    result.z = float<-(read(mat)[6] * px + read(mat)[7] * py + read(mat)[8] * pz)
    return result


function whose_mouse(state: ref[AppState], mouse: sdl.MouseID) -> int:
    for i in 0..state.player_count:
        if state.players[i].mouse == mouse:
            return i
    return -1


function whose_keyboard(state: ref[AppState], keyboard: sdl.KeyboardID) -> int:
    for i in 0..state.player_count:
        if state.players[i].keyboard == keyboard:
            return i
    return -1


function shoot(state: ref[AppState], shooter: int) -> void:
    let x0 = state.players[shooter].pos[0]
    let y0 = state.players[shooter].pos[1]
    let z0 = state.players[shooter].pos[2]
    let yaw_rad = BIN_RAD * state.players[shooter].yaw
    let pitch_rad = BIN_RAD * state.players[shooter].pitch
    let cos_yaw = sdl.cos(yaw_rad)
    let sin_yaw = sdl.sin(yaw_rad)
    let cos_pitch = sdl.cos(pitch_rad)
    let sin_pitch = sdl.sin(pitch_rad)
    let vx = -sin_yaw * cos_pitch
    let vy = sin_pitch
    let vz = -cos_yaw * cos_pitch

    for i in 0..state.player_count:
        if i == shooter:
            continue
        let r = double<-state.players[i].radius
        let h = double<-state.players[i].height
        var hit = 0
        for j in 0..2:
            let dx = state.players[i].pos[0] - x0
            let dy = state.players[i].pos[1] - y0 + (if j == 0: 0.0d else: r - h)
            let dz = state.players[i].pos[2] - z0
            let vd = vx * dx + vy * dy + vz * dz
            let dd = dx * dx + dy * dy + dz * dz
            let vv = vx * vx + vy * vy + vz * vz
            let rr = r * r
            if vd >= 0 and vd * vd >= vv * (dd - rr):
                hit += 1
        if hit > 0:
            state.players[i].pos[0] = (MAP_BOX_SCALE * (sdl.rand(256) - 128)) / 256.0d
            state.players[i].pos[1] = (MAP_BOX_SCALE * (sdl.rand(256) - 128)) / 256.0d
            state.players[i].pos[2] = (MAP_BOX_SCALE * (sdl.rand(256) - 128)) / 256.0d


function update_players(state: ref[AppState], dt_ns: ptr_uint) -> void:
    let rate = 6.0d
    let time = dt_ns * 1e-9d
    let drag = sdl.exp(-time * rate)
    let diff = 1.0d - drag
    let mult = 60.0d
    let grav = 25.0d

    for i in 0..state.player_count:
        let yaw = double<-state.players[i].yaw
        let rad = yaw * BIN_RAD
        let cos_yaw = sdl.cos(rad)
        let sin_yaw = sdl.sin(rad)
        let wasd = state.players[i].wasd
        let dir_x = wasd_axis(int<-wasd, int<-WASD_RIGHT, int<-WASD_LEFT)
        let dir_z = wasd_axis(int<-wasd, int<-WASD_BACK, int<-WASD_FORWARD)
        let norm = dir_x * dir_x + dir_z * dir_z
        let acc_x = mult * (if norm == 0: 0.0d else: (cos_yaw * dir_x + sin_yaw * dir_z) / sdl.sqrt(norm))
        let acc_z = mult * (if norm == 0: 0.0d else: (-sin_yaw * dir_x + cos_yaw * dir_z) / sdl.sqrt(norm))
        let vel_x = state.players[i].vel[0]
        let vel_y = state.players[i].vel[1]
        let vel_z = state.players[i].vel[2]

        state.players[i].vel[0] = state.players[i].vel[0] - vel_x * diff
        state.players[i].vel[1] = state.players[i].vel[1] - grav * time
        state.players[i].vel[2] = state.players[i].vel[2] - vel_z * diff
        state.players[i].vel[0] = state.players[i].vel[0] + diff * acc_x / rate
        state.players[i].vel[2] = state.players[i].vel[2] + diff * acc_z / rate
        state.players[i].pos[0] = state.players[i].pos[0] + (time - diff / rate) * acc_x / rate + diff * vel_x / rate
        state.players[i].pos[1] = state.players[i].pos[1] + -0.5d * grav * time * time + vel_y * time
        state.players[i].pos[2] = state.players[i].pos[2] + (time - diff / rate) * acc_z / rate + diff * vel_z / rate

        let scale = double<-MAP_BOX_SCALE
        let bound = scale - double<-state.players[i].radius
        let pos_x = fmax(fmin(bound, state.players[i].pos[0]), -bound)
        let pos_y = fmax(fmin(bound, state.players[i].pos[1]), double<-state.players[i].height - scale)
        let pos_z = fmax(fmin(bound, state.players[i].pos[2]), -bound)
        if state.players[i].pos[0] != pos_x:
            state.players[i].vel[0] = 0.0d
        if state.players[i].pos[1] != pos_y:
            state.players[i].vel[1] = (if (int<-wasd & int<-WASD_JUMP) != 0: 8.4375d else: 0.0d)
        if state.players[i].pos[2] != pos_z:
            state.players[i].vel[2] = 0.0d
        state.players[i].pos[0] = pos_x
        state.players[i].pos[1] = pos_y
        state.players[i].pos[2] = pos_z


function draw_circle(renderer: sdl.Renderer, r: float, x: float, y: float) -> void:
    var points: array[sdl.FPoint, CIRCLE_DRAW_SIDES_LEN]
    for i in 0..CIRCLE_DRAW_SIDES_LEN:
        let ang = 2.0 * sdl.PI_F * i / CIRCLE_DRAW_SIDES
        points[i].x = x + r * sdl.cosf(ang)
        points[i].y = y + r * sdl.sinf(ang)
    sdl.render_lines(renderer, points.as_span())


function draw_clipped_segment(
    renderer: sdl.Renderer,
    ax: float, ay: float, az: float,
    bx: float, by: float, bz: float,
    x: float, y: float, z: float, w: float
) -> void:
    if az >= -w and bz >= -w:
        return

    var axv = ax
    var ayv = ay
    var azv = az
    var bxv = bx
    var byv = by
    var bzv = bz
    let dx = axv - bxv
    let dy = ayv - byv
    if azv > -w:
        let t = (-w - bzv) / (azv - bzv)
        axv = bxv + dx * t
        ayv = byv + dy * t
        azv = -w
    else if bzv > -w:
        let t = (-w - azv) / (bzv - azv)
        bxv = axv - dx * t
        byv = ayv - dy * t
        bzv = -w
    axv = -z * axv / azv
    ayv = -z * ayv / azv
    bxv = -z * bxv / bzv
    byv = -z * byv / bzv
    sdl.render_line(renderer, x + axv, y - ayv, x + bxv, y - byv)


function draw(state: ref[AppState], renderer: sdl.Renderer) -> void:
    var w = 0
    var h = 0
    if not sdl.get_render_output_size(renderer, w, h):
        return

    sdl.set_render_draw_color(renderer, 0, 0, 0, sdl.ALPHA_OPAQUE)
    sdl.render_clear(renderer)

    if state.player_count > 0:
        let wf = float<-w
        let hf = float<-h
        let part_hor = if state.player_count > 2: 2 else: 1
        let part_ver = if state.player_count > 1: 2 else: 1
        let size_hor = wf / part_hor
        let size_ver = hf / part_ver

        for i in 0..state.player_count:
            let mod_x = i % part_hor
            let mod_y = i / part_hor
            let hor_origin = (mod_x + 0.5) * size_hor
            let ver_origin = (mod_y + 0.5) * size_ver
            let cam_origin = float<-(0.5d * sdl.sqrt(double<-size_hor * size_hor + size_ver * size_ver))
            let hor_offset = mod_x * size_hor
            let ver_offset = mod_y * size_ver

            var rect: sdl.Rect
            rect.x = int<-hor_offset
            rect.y = int<-ver_offset
            rect.w = int<-size_hor
            rect.h = int<-size_ver
            sdl.set_render_clip_rect(renderer, const_ptr_of(rect))

            let x0 = state.players[i].pos[0]
            let y0 = state.players[i].pos[1]
            let z0 = state.players[i].pos[2]
            let yaw_rad = BIN_RAD * state.players[i].yaw
            let pitch_rad = BIN_RAD * state.players[i].pitch
            let cos_yaw = sdl.cos(yaw_rad)
            let sin_yaw = sdl.sin(yaw_rad)
            let cos_pitch = sdl.cos(pitch_rad)
            let sin_pitch = sdl.sin(pitch_rad)
            var mat: array[double, 9]
            mat[0] = cos_yaw
            mat[1] = 0.0d
            mat[2] = -sin_yaw
            mat[3] = sin_yaw * sin_pitch
            mat[4] = cos_pitch
            mat[5] = cos_yaw * sin_pitch
            mat[6] = sin_yaw * cos_pitch
            mat[7] = -sin_pitch
            mat[8] = cos_yaw * cos_pitch

            sdl.set_render_draw_color(renderer, 64, 64, 64, sdl.ALPHA_OPAQUE)
            for k in 0..MAP_BOX_EDGES_LEN:
                let eax = state.edges[k][0] - x0
                let eay = state.edges[k][1] - y0
                let eaz = state.edges[k][2] - z0
                let ebx = state.edges[k][3] - x0
                let eby = state.edges[k][4] - y0
                let ebz = state.edges[k][5] - z0
                let a = rotate_point(ref_of(mat), eax, eay, eaz)
                let b = rotate_point(ref_of(mat), ebx, eby, ebz)
                draw_clipped_segment(renderer, a.x, a.y, a.z, b.x, b.y, b.z, hor_origin, ver_origin, cam_origin, 1.0)

            for j in 0..state.player_count:
                if i == j:
                    continue
                sdl.set_render_draw_color(
                    renderer,
                    state.players[j].color[0],
                    state.players[j].color[1],
                    state.players[j].color[2],
                    sdl.ALPHA_OPAQUE
                )
                for k in 0..2:
                    let rx = state.players[j].pos[0] - state.players[i].pos[0]
                    let body_offset = (state.players[j].radius - state.players[j].height) * k
                    let ry = state.players[j].pos[1] - state.players[i].pos[1] + body_offset
                    let rz = state.players[j].pos[2] - state.players[i].pos[2]
                    let dx = mat[0] * rx + mat[1] * ry + mat[2] * rz
                    let dy = mat[3] * rx + mat[4] * ry + mat[5] * rz
                    let dz = mat[6] * rx + mat[7] * ry + mat[8] * rz
                    let r_eff = state.players[j].radius * cam_origin / dz
                    if dz < 0:
                        let circle_x = float<-(hor_origin - cam_origin * dx / dz)
                        let circle_y = float<-(ver_origin + cam_origin * dy / dz)
                        draw_circle(renderer, float<-r_eff, circle_x, circle_y)

            sdl.set_render_draw_color(renderer, 255, 255, 255, sdl.ALPHA_OPAQUE)
            sdl.render_line(renderer, hor_origin, ver_origin - 10, hor_origin, ver_origin + 10)
            sdl.render_line(renderer, hor_origin - 10, ver_origin, hor_origin + 10, ver_origin)

    sdl.set_render_clip_rect(renderer, null)
    sdl.set_render_draw_color(renderer, 255, 255, 255, sdl.ALPHA_OPAQUE)
    sdl.render_debug_text(renderer, 0, 0, state.debug_string.as_str())
    sdl.render_present(renderer)


function invert_if_odd(value: ubyte, odd: bool) -> ubyte:
    return ubyte<-(if odd: int<-value else: ~int<-value)


function init_players(state: ref[AppState]) -> void:
    for i in 0..MAX_PLAYER_COUNT:
        state.players[i].pos[0] = 8.0d * (if (i & 1) != 0: -1.0d else: 1.0d)
        state.players[i].pos[1] = 0.0d
        state.players[i].pos[2] = 8.0d * (if (i & 1) != 0: -1.0d else: 1.0d) * (if (i & 2) != 0: -1.0d else: 1.0d)
        state.players[i].vel[0] = 0.0d
        state.players[i].vel[1] = 0.0d
        state.players[i].vel[2] = 0.0d
        let yaw_offset = uint<-0x20000000 + (if (i & 1) != 0: uint<-0x80000000 else: uint<-0)
        state.players[i].yaw = yaw_offset + (if (i & 2) != 0: uint<-0x40000000 else: uint<-0)
        state.players[i].pitch = -0x08000000
        state.players[i].radius = 0.5
        state.players[i].height = 1.5
        state.players[i].wasd = 0
        state.players[i].mouse = 0
        state.players[i].keyboard = 0
        state.players[i].color[0] = ubyte<-(if ((1 << (i / 2)) & 2) != 0: 0 else: 255)
        state.players[i].color[1] = ubyte<-(if ((1 << (i / 2)) & 1) != 0: 0 else: 255)
        state.players[i].color[2] = ubyte<-(if ((1 << (i / 2)) & 4) != 0: 0 else: 255)
        state.players[i].color[0] = invert_if_odd(state.players[i].color[0], (i & 1) != 0)
        state.players[i].color[1] = invert_if_odd(state.players[i].color[1], (i & 1) != 0)
        state.players[i].color[2] = invert_if_odd(state.players[i].color[2], (i & 1) != 0)


function init_edges(state: ref[AppState]) -> void:
    let r = float<-MAP_BOX_SCALE
    for i in 0..12:
        for j in 0..3:
            state.edges[i][j] = if (EDGE_MAP[i * 2] & (1 << j)) != 0: r else: -r
            state.edges[i][j + 3] = if (EDGE_MAP[i * 2 + 1] & (1 << j)) != 0: r else: -r
    for i in 0..MAP_BOX_SCALE:
        let d = float<-(i * 2)
        for j in 0..2:
            state.edges[i + 12][j * 3] = if j != 0: r else: -r
            state.edges[i + 12][j * 3 + 1] = -r
            state.edges[i + 12][j * 3 + 2] = d - r
            state.edges[i + 12 + MAP_BOX_SCALE][j * 3] = d - r
            state.edges[i + 12 + MAP_BOX_SCALE][j * 3 + 1] = -r
            state.edges[i + 12 + MAP_BOX_SCALE][j * 3 + 2] = if j != 0: r else: -r


function main() -> int:
    if not sdl.set_app_metadata("Example splitscreen shooter game", "1.0", "com.example.woodeneye-008"):
        pass

    if not sdl.init(sdl.INIT_VIDEO):
        fatal(f"could not initialize SDL: #{sdl.get_error()}")
    defer: sdl.quit()

    var window: sdl.Window = zero[sdl.Window]
    var renderer: sdl.Renderer = zero[sdl.Renderer]
    if not sdl.create_window_and_renderer(
        "examples/demo/woodeneye-008",
        640,
        480,
        sdl.WINDOW_RESIZABLE,
        window,
        renderer
    ):
        fatal(f"could not create window/renderer: #{sdl.get_error()}")
    defer: sdl.destroy_renderer(renderer)
    defer: sdl.destroy_window(window)

    sdl.set_window_relative_mouse_mode(window, true)
    sdl.set_hint_with_priority("SDL_WINDOWS_RAW_KEYBOARD", "1", sdl.HintPriority.SDL_HINT_OVERRIDE)

    var state: AppState
    state.player_count = 1
    init_players(ref_of(state))
    init_edges(ref_of(state))
    state.debug_string.assign("")

    var running = true
    var past = sdl.get_ticks_ns()
    var last = past
    var accu: ptr_uint = 0
    while running:
        var ev: sdl.Event = zero[sdl.Event]
        while sdl.poll_event(ev):
            let ev_type = int<-ev.type
            if ev_type == int<-sdl.EventType.SDL_EVENT_QUIT:
                running = false
            else if ev_type == int<-sdl.EventType.SDL_EVENT_MOUSE_REMOVED:
                for i in 0..state.player_count:
                    if state.players[i].mouse == ev.mdevice.which:
                        state.players[i].mouse = 0
            else if ev_type == int<-sdl.EventType.SDL_EVENT_KEYBOARD_REMOVED:
                for i in 0..state.player_count:
                    if state.players[i].keyboard == ev.kdevice.which:
                        state.players[i].keyboard = 0
            else if ev_type == int<-sdl.EventType.SDL_EVENT_MOUSE_MOTION:
                let index = whose_mouse(ref_of(state), ev.motion.which)
                if index >= 0:
                    state.players[index].yaw = state.players[index].yaw - uint<-(int<-ev.motion.xrel * 0x00080000)
                    state.players[index].pitch = imax(
                        -0x40000000,
                        imin(0x40000000, state.players[index].pitch - int<-ev.motion.yrel * 0x00080000)
                    )
                else if ev.motion.which != 0:
                    for i in 0..MAX_PLAYER_COUNT:
                        if state.players[i].mouse == 0:
                            state.players[i].mouse = ev.motion.which
                            state.player_count = imax(state.player_count, i + 1)
                            break
            else if ev_type == int<-sdl.EventType.SDL_EVENT_MOUSE_BUTTON_DOWN:
                let index = whose_mouse(ref_of(state), ev.button.which)
                if index >= 0:
                    shoot(ref_of(state), index)
            else if ev_type == int<-sdl.EventType.SDL_EVENT_KEY_DOWN:
                let index = whose_keyboard(ref_of(state), ev.key.which)
                if index >= 0:
                    if ev.key.scancode == sdl.Scancode.SDL_SCANCODE_W:
                        state.players[index].wasd |= WASD_FORWARD
                    else if ev.key.scancode == sdl.Scancode.SDL_SCANCODE_A:
                        state.players[index].wasd |= WASD_LEFT
                    else if ev.key.scancode == sdl.Scancode.SDL_SCANCODE_S:
                        state.players[index].wasd |= WASD_BACK
                    else if ev.key.scancode == sdl.Scancode.SDL_SCANCODE_D:
                        state.players[index].wasd |= WASD_RIGHT
                    else if ev.key.scancode == sdl.Scancode.SDL_SCANCODE_SPACE:
                        state.players[index].wasd |= WASD_JUMP
                else if ev.key.which != 0:
                    for i in 0..MAX_PLAYER_COUNT:
                        if state.players[i].keyboard == 0:
                            state.players[i].keyboard = ev.key.which
                            state.player_count = imax(state.player_count, i + 1)
                            break
            else if ev_type == int<-sdl.EventType.SDL_EVENT_KEY_UP:
                if ev.key.scancode == sdl.Scancode.SDL_SCANCODE_ESCAPE:
                    running = false
                let index = whose_keyboard(ref_of(state), ev.key.which)
                if index >= 0:
                    if ev.key.scancode == sdl.Scancode.SDL_SCANCODE_W:
                        state.players[index].wasd &= 30
                    else if ev.key.scancode == sdl.Scancode.SDL_SCANCODE_A:
                        state.players[index].wasd &= 29
                    else if ev.key.scancode == sdl.Scancode.SDL_SCANCODE_S:
                        state.players[index].wasd &= 27
                    else if ev.key.scancode == sdl.Scancode.SDL_SCANCODE_D:
                        state.players[index].wasd &= 23
                    else if ev.key.scancode == sdl.Scancode.SDL_SCANCODE_SPACE:
                        state.players[index].wasd &= 15

        let now = sdl.get_ticks_ns()
        update_players(ref_of(state), now - past)
        draw(ref_of(state), renderer)
        if now - last > ptr_uint<-999999999:
            last = now
            state.debug_string.assign_format(f"#{accu} fps")
            accu = 0
        past = now
        accu += 1
        let elapsed = sdl.get_ticks_ns() - now
        if elapsed < ptr_uint<-999999:
            sdl.delay_ns(ptr_uint<-999999 - elapsed)

    return 0
