module examples.sdl3.demo.woodeneye_008

import std.c.sdl3 as c

const map_box_scale: int = 16
const map_box_edges_len: int = 12 + (map_box_scale * 2)
const max_player_count: int = 4
const circle_draw_sides: int = 32
const circle_draw_sides_len: int = circle_draw_sides + 1
const window_width: int = 640
const window_height: int = 480
const window_title: cstr = c"examples/demo/woodeneye-008"
const window_flags: ulong = ulong<-c.SDL_WINDOW_RESIZABLE
const mouse_turn_step: int = 524288
const pitch_min: int = -1073741824
const pitch_max: int = 1073741824
const initial_pitch: int = -134217728
const frame_ns: c.Uint64 = 999999

struct Player:
    mouse: c.SDL_MouseID
    keyboard: c.SDL_KeyboardID
    pos: array[double, 3]
    vel: array[double, 3]
    yaw: long
    pitch: int
    radius: float
    height: float
    color: array[ubyte, 3]
    wasd: ubyte

const initial_yaws: array[long, 4] = array[long, 4](536870912, 2684354560, 1610612736, 3758096384)
const box_edge_map: array[int, 24] = array[int, 24](
    0, 1, 1, 3, 3, 2, 2, 0,
    7, 6, 6, 4, 4, 5, 5, 7,
    6, 2, 3, 7, 0, 4, 5, 1,
)

var window: ptr[c.SDL_Window]
var renderer: ptr[c.SDL_Renderer]
var player_count: int = 1
var players: array[Player, 4] = zero[array[Player, 4]]
var edges: array[array[float, 6], 44] = zero[array[array[float, 6], 44]]
var displayed_fps: c.Uint64 = 0
var frames_accumulated: c.Uint64 = 0
var fps_last_tick: c.Uint64 = 0
var past_tick: c.Uint64 = 0


def min_double(lhs: double, rhs: double) -> double:
    if lhs < rhs:
        return lhs

    return rhs


def max_double(lhs: double, rhs: double) -> double:
    if lhs > rhs:
        return lhs

    return rhs


def clamp_double(value: double, min_value: double, max_value: double) -> double:
    return max_double(min_value, min_double(max_value, value))


def clamp_int(value: int, min_value: int, max_value: int) -> int:
    if value < min_value:
        return min_value
    if value > max_value:
        return max_value

    return value


def whose_mouse(mouse: c.SDL_MouseID) -> int:
    for index in 0..player_count:
        if players[index].mouse == mouse:
            return index

    return -1


def whose_keyboard(keyboard: c.SDL_KeyboardID) -> int:
    for index in 0..player_count:
        if players[index].keyboard == keyboard:
            return index

    return -1


def set_player_color(index: int) -> void:
    if index == 0:
        players[index].color[0] = 0
        players[index].color[1] = 255
        players[index].color[2] = 0
        return

    if index == 1:
        players[index].color[0] = 255
        players[index].color[1] = 0
        players[index].color[2] = 255
        return

    if index == 2:
        players[index].color[0] = 255
        players[index].color[1] = 0
        players[index].color[2] = 0
        return

    players[index].color[0] = 0
    players[index].color[1] = 255
    players[index].color[2] = 255


def respawn_player(index: int) -> void:
    players[index].pos[0] = double<-(map_box_scale * (c.SDL_rand(256) - 128)) / 256.0
    players[index].pos[1] = double<-(map_box_scale * (c.SDL_rand(256) - 128)) / 256.0
    players[index].pos[2] = double<-(map_box_scale * (c.SDL_rand(256) - 128)) / 256.0


def initialize_player(index: int) -> void:
    let x_sign = if (index & 1) != 0: -1.0 else: 1.0
    let z_sign = if (index & 2) != 0: -1.0 else: 1.0

    players[index].pos[0] = 8.0 * x_sign
    players[index].pos[1] = 0.0
    players[index].pos[2] = 8.0 * x_sign * z_sign
    players[index].vel[0] = 0.0
    players[index].vel[1] = 0.0
    players[index].vel[2] = 0.0
    players[index].yaw = initial_yaws[index]
    players[index].pitch = initial_pitch
    players[index].radius = 0.5
    players[index].height = 1.5
    players[index].wasd = 0
    players[index].mouse = 0
    players[index].keyboard = 0
    set_player_color(index)


def init_players() -> void:
    for index in 0..max_player_count:
        initialize_player(index)


def init_edges() -> void:
    let bound = float<-map_box_scale

    for index in 0..12:
        for axis in 0..3:
            edges[index][axis] = if (box_edge_map[index * 2] & (1 << axis)) != 0: bound else: -bound
            edges[index][axis + 3] = if (box_edge_map[index * 2 + 1] & (1 << axis)) != 0: bound else: -bound

    for index in 0..map_box_scale:
        let distance = float<-(index * 2) - bound

        for endpoint in 0..2:
            edges[index + 12][endpoint * 3] = if endpoint != 0: bound else: -bound
            edges[index + 12][endpoint * 3 + 1] = -bound
            edges[index + 12][endpoint * 3 + 2] = distance
            edges[index + 12 + map_box_scale][endpoint * 3] = distance
            edges[index + 12 + map_box_scale][endpoint * 3 + 1] = -bound
            edges[index + 12 + map_box_scale][endpoint * 3 + 2] = if endpoint != 0: bound else: -bound


def shoot(shooter: int) -> void:
    let x0 = players[shooter].pos[0]
    let y0 = players[shooter].pos[1]
    let z0 = players[shooter].pos[2]
    let yaw_rad = double<-players[shooter].yaw * c.SDL_PI_D / 2147483648.0
    let pitch_rad = double<-players[shooter].pitch * c.SDL_PI_D / 2147483648.0
    let cos_yaw = c.SDL_cos(yaw_rad)
    let sin_yaw = c.SDL_sin(yaw_rad)
    let cos_pitch = c.SDL_cos(pitch_rad)
    let sin_pitch = c.SDL_sin(pitch_rad)
    let vx = -sin_yaw * cos_pitch
    let vy = sin_pitch
    let vz = -cos_yaw * cos_pitch

    for index in 0..player_count:
        if index == shooter:
            continue

        var hit = 0

        for circle_index in 0..2:
            let radius = double<-players[index].radius
            let height = double<-players[index].height
            let dx = players[index].pos[0] - x0
            let y_offset = if circle_index == 0: 0.0 else: radius - height
            let dy = players[index].pos[1] - y0 + y_offset
            let dz = players[index].pos[2] - z0
            let vd = (vx * dx) + (vy * dy) + (vz * dz)
            let dd = (dx * dx) + (dy * dy) + (dz * dz)
            let vv = (vx * vx) + (vy * vy) + (vz * vz)
            let rr = radius * radius

            if vd >= 0.0:
                if (vd * vd) >= (vv * (dd - rr)):
                    hit += 1

        if hit != 0:
            respawn_player(index)


def update_players(dt_ns: c.Uint64) -> void:
    for index in 0..player_count:
        let time = double<-dt_ns * 1.0e-9
        let drag = c.SDL_exp(-time * 6.0)
        let diff = 1.0 - drag
        let yaw_rad = double<-players[index].yaw * c.SDL_PI_D / 2147483648.0
        let cosine = c.SDL_cos(yaw_rad)
        let sine = c.SDL_sin(yaw_rad)
        let wasd = players[index].wasd
        let dir_x = (if (wasd & 8) != 0: 1.0 else: 0.0) - (if (wasd & 2) != 0: 1.0 else: 0.0)
        let dir_z = (if (wasd & 4) != 0: 1.0 else: 0.0) - (if (wasd & 1) != 0: 1.0 else: 0.0)
        let norm = (dir_x * dir_x) + (dir_z * dir_z)
        let acc_x = if norm == 0.0: 0.0 else: 60.0 * ((cosine * dir_x + sine * dir_z) / c.SDL_sqrt(norm))
        let acc_z = if norm == 0.0: 0.0 else: 60.0 * ((-sine * dir_x + cosine * dir_z) / c.SDL_sqrt(norm))
        let vel_x = players[index].vel[0]
        let vel_y = players[index].vel[1]
        let vel_z = players[index].vel[2]
        let new_pos_x = players[index].pos[0] + (((time - (diff / 6.0)) * acc_x) / 6.0) + ((diff * vel_x) / 6.0)
        let new_pos_y = players[index].pos[1] + (-0.5 * 25.0 * time * time) + (vel_y * time)
        let new_pos_z = players[index].pos[2] + (((time - (diff / 6.0)) * acc_z) / 6.0) + ((diff * vel_z) / 6.0)
        let bound = double<-map_box_scale - double<-players[index].radius
        let clamped_x = clamp_double(new_pos_x, -bound, bound)
        let clamped_y = clamp_double(new_pos_y, double<-players[index].height - double<-map_box_scale, bound)
        let clamped_z = clamp_double(new_pos_z, -bound, bound)

        players[index].vel[0] = vel_x - (vel_x * diff) + ((diff * acc_x) / 6.0)
        players[index].vel[1] = vel_y - (25.0 * time)
        players[index].vel[2] = vel_z - (vel_z * diff) + ((diff * acc_z) / 6.0)

        if new_pos_x != clamped_x:
            players[index].vel[0] = 0.0
        if new_pos_y != clamped_y:
            players[index].vel[1] = if (wasd & 16) != 0: 8.4375 else: 0.0
        if new_pos_z != clamped_z:
            players[index].vel[2] = 0.0

        players[index].pos[0] = clamped_x
        players[index].pos[1] = clamped_y
        players[index].pos[2] = clamped_z


def draw_circle(radius: float, x: float, y: float) -> void:
    var points = zero[array[c.SDL_FPoint, 33]]

    for index in 0..circle_draw_sides_len:
        let angle = (2.0 * c.SDL_PI_F * float<-index) / float<-circle_draw_sides
        points[index].x = x + (radius * c.SDL_cosf(angle))
        points[index].y = y + (radius * c.SDL_sinf(angle))

    c.SDL_RenderLines(renderer, ptr_of(points[0]), circle_draw_sides_len)


def draw_clipped_segment(ax: float, ay: float, az: float, bx: float, by: float, bz: float, x: float, y: float, z: float, w: float) -> void:
    var start_x = ax
    var start_y = ay
    var start_z = az
    var end_x = bx
    var end_y = by
    var end_z = bz

    if start_z >= -w and end_z >= -w:
        return

    let delta_x = start_x - end_x
    let delta_y = start_y - end_y

    if start_z > -w:
        let t = (-w - end_z) / (start_z - end_z)
        start_x = end_x + (delta_x * t)
        start_y = end_y + (delta_y * t)
        start_z = -w
    else:
        if end_z > -w:
            let t = (-w - start_z) / (end_z - start_z)
            end_x = start_x - (delta_x * t)
            end_y = start_y - (delta_y * t)
            end_z = -w

    start_x = -z * start_x / start_z
    start_y = -z * start_y / start_z
    end_x = -z * end_x / end_z
    end_y = -z * end_y / end_z
    c.SDL_RenderLine(renderer, x + start_x, y - start_y, x + end_x, y - end_y)


def render_frame() -> void:
    var output_width: int = 0
    var output_height: int = 0

    if not c.SDL_GetRenderOutputSize(renderer, ptr_of(output_width), ptr_of(output_height)):
        return

    c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderClear(renderer)

    if player_count > 0:
        let part_hor = if player_count > 2: 2 else: 1
        let part_ver = if player_count > 1: 2 else: 1
        let size_hor = float<-output_width / float<-part_hor
        let size_ver = float<-output_height / float<-part_ver

        for player_index in 0..player_count:
            let hor_origin = (float<-(player_index % part_hor) + 0.5) * size_hor
            let ver_origin = (float<-(player_index / part_hor) + 0.5) * size_ver
            let cam_origin = float<-(0.5 * c.SDL_sqrt(double<-((size_hor * size_hor) + (size_ver * size_ver))))
            let hor_offset = float<-(player_index % part_hor) * size_hor
            let ver_offset = float<-(player_index / part_hor) * size_ver
            let yaw_rad = double<-players[player_index].yaw * c.SDL_PI_D / 2147483648.0
            let pitch_rad = double<-players[player_index].pitch * c.SDL_PI_D / 2147483648.0
            let cos_yaw = c.SDL_cos(yaw_rad)
            let sin_yaw = c.SDL_sin(yaw_rad)
            let cos_pitch = c.SDL_cos(pitch_rad)
            let sin_pitch = c.SDL_sin(pitch_rad)
            let px = players[player_index].pos[0]
            let py = players[player_index].pos[1]
            let pz = players[player_index].pos[2]
            var clip_rect = c.SDL_Rect(x = int<-hor_offset, y = int<-ver_offset, w = int<-size_hor, h = int<-size_ver)
            var mat = array[double, 9](
                cos_yaw, 0.0, -sin_yaw,
                sin_yaw * sin_pitch, cos_pitch, cos_yaw * sin_pitch,
                sin_yaw * cos_pitch, -sin_pitch, cos_yaw * cos_pitch,
            )

            c.SDL_SetRenderClipRect(renderer, ptr_of(clip_rect))
            c.SDL_SetRenderDrawColor(renderer, 64, 64, 64, c.SDL_ALPHA_OPAQUE)

            for edge_index in 0..map_box_edges_len:
                let line = edges[edge_index]
                let line_ax = double<-line[0]
                let line_ay = double<-line[1]
                let line_az = double<-line[2]
                let line_bx = double<-line[3]
                let line_by = double<-line[4]
                let line_bz = double<-line[5]
                let ax = mat[0] * (line_ax - px) + mat[1] * (line_ay - py) + mat[2] * (line_az - pz)
                let ay = mat[3] * (line_ax - px) + mat[4] * (line_ay - py) + mat[5] * (line_az - pz)
                let az = mat[6] * (line_ax - px) + mat[7] * (line_ay - py) + mat[8] * (line_az - pz)
                let bx = mat[0] * (line_bx - px) + mat[1] * (line_by - py) + mat[2] * (line_bz - pz)
                let by = mat[3] * (line_bx - px) + mat[4] * (line_by - py) + mat[5] * (line_bz - pz)
                let bz = mat[6] * (line_bx - px) + mat[7] * (line_by - py) + mat[8] * (line_bz - pz)

                draw_clipped_segment(float<-ax, float<-ay, float<-az, float<-bx, float<-by, float<-bz, hor_origin, ver_origin, cam_origin, 1.0)

            for target_index in 0..player_count:
                if player_index == target_index:
                    continue

                c.SDL_SetRenderDrawColor(renderer, players[target_index].color[0], players[target_index].color[1], players[target_index].color[2], c.SDL_ALPHA_OPAQUE)

                for circle_index in 0..2:
                    let rx = players[target_index].pos[0] - px
                    let ry = players[target_index].pos[1] - py + (double<-(players[target_index].radius - players[target_index].height) * double<-circle_index)
                    let rz = players[target_index].pos[2] - pz
                    let dx = mat[0] * rx + mat[1] * ry + mat[2] * rz
                    let dy = mat[3] * rx + mat[4] * ry + mat[5] * rz
                    let dz = mat[6] * rx + mat[7] * ry + mat[8] * rz

                    if dz < 0.0:
                        let effective_radius = float<-(double<-players[target_index].radius * double<-cam_origin / dz)
                        let draw_x = hor_origin - float<-(double<-cam_origin * dx / dz)
                        let draw_y = ver_origin + float<-(double<-cam_origin * dy / dz)
                        draw_circle(effective_radius, draw_x, draw_y)

            c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, c.SDL_ALPHA_OPAQUE)
            c.SDL_RenderLine(renderer, hor_origin, ver_origin - 10.0, hor_origin, ver_origin + 10.0)
            c.SDL_RenderLine(renderer, hor_origin - 10.0, ver_origin, hor_origin + 10.0, ver_origin)

    c.SDL_SetRenderClipRect(renderer, null)
    c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, c.SDL_ALPHA_OPAQUE)
    c.SDL_RenderDebugTextFormat(renderer, 0.0, 0.0, c"%zu fps", displayed_fps)
    c.SDL_RenderPresent(renderer)


def set_wasd_bit(player_index: int, scancode: c.SDL_Scancode, pressed: bool) -> void:
    var mask: ubyte = 0

    if scancode == c.SDL_Scancode.SDL_SCANCODE_W:
        mask = 1
    else:
        if scancode == c.SDL_Scancode.SDL_SCANCODE_A:
            mask = 2
        else:
            if scancode == c.SDL_Scancode.SDL_SCANCODE_S:
                mask = 4
            else:
                if scancode == c.SDL_Scancode.SDL_SCANCODE_D:
                    mask = 8
                else:
                    if scancode == c.SDL_Scancode.SDL_SCANCODE_SPACE:
                        mask = 16

    if mask == 0:
        return

    if pressed:
        players[player_index].wasd |= mask
    else:
        players[player_index].wasd &= ubyte<-~mask


def pump_events() -> bool:
    var event = zero[c.SDL_Event]

    while c.SDL_PollEvent(ptr_of(event)):
        if event.type_ == uint<-c.SDL_EventType.SDL_EVENT_QUIT:
            return false

        if event.type_ == uint<-c.SDL_EventType.SDL_EVENT_MOUSE_REMOVED:
            for index in 0..player_count:
                if players[index].mouse == event.mdevice.which:
                    players[index].mouse = 0
            continue

        if event.type_ == uint<-c.SDL_EventType.SDL_EVENT_KEYBOARD_REMOVED:
            for index in 0..player_count:
                if players[index].keyboard == event.kdevice.which:
                    players[index].keyboard = 0
            continue

        if event.type_ == uint<-c.SDL_EventType.SDL_EVENT_MOUSE_MOTION:
            let mouse_id = event.motion.which
            let player_index = whose_mouse(mouse_id)

            if player_index >= 0:
                players[player_index].yaw -= long<-(int<-event.motion.xrel * mouse_turn_step)
                players[player_index].pitch = clamp_int(players[player_index].pitch - (int<-event.motion.yrel * mouse_turn_step), pitch_min, pitch_max)
            else:
                if mouse_id != 0:
                    for index in 0..max_player_count:
                        if players[index].mouse == 0:
                            players[index].mouse = mouse_id
                            if player_count < index + 1:
                                player_count = index + 1
                            break
            continue

        if event.type_ == uint<-c.SDL_EventType.SDL_EVENT_MOUSE_BUTTON_DOWN:
            let player_index = whose_mouse(event.button.which)
            if player_index >= 0:
                shoot(player_index)
            continue

        if event.type_ == uint<-c.SDL_EventType.SDL_EVENT_KEY_DOWN:
            let player_index = whose_keyboard(event.key.which)

            if player_index >= 0:
                set_wasd_bit(player_index, event.key.scancode, true)
            else:
                if event.key.which != 0:
                    for index in 0..max_player_count:
                        if players[index].keyboard == 0:
                            players[index].keyboard = event.key.which
                            if player_count < index + 1:
                                player_count = index + 1
                            break
            continue

        if event.type_ == uint<-c.SDL_EventType.SDL_EVENT_KEY_UP:
            if event.key.scancode == c.SDL_Scancode.SDL_SCANCODE_ESCAPE:
                return false

            let player_index = whose_keyboard(event.key.which)
            if player_index >= 0:
                set_wasd_bit(player_index, event.key.scancode, false)

    return true


def app_main(argc: int, argv: ptr[ptr[char]]) -> int:
    c.SDL_SetAppMetadata(c"Example splitscreen shooter game", c"1.0", c"com.example.woodeneye-008")
    c.SDL_SetAppMetadataProperty(c"SDL.app.metadata.url", c"https://examples.libsdl.org/SDL3/demo/02-woodeneye-008/")
    c.SDL_SetAppMetadataProperty(c"SDL.app.metadata.creator", c"SDL team")
    c.SDL_SetAppMetadataProperty(c"SDL.app.metadata.copyright", c"Placed in the public domain")
    c.SDL_SetAppMetadataProperty(c"SDL.app.metadata.kind", c"game")

    if not c.SDL_Init(c.SDL_INIT_VIDEO):
        return 1
    defer c.SDL_Quit()

    if not c.SDL_CreateWindowAndRenderer(window_title, window_width, window_height, window_flags, ptr_of(window), ptr_of(renderer)):
        return 1
    defer c.SDL_DestroyRenderer(renderer)
    defer c.SDL_DestroyWindow(window)

    player_count = 1
    init_players()
    init_edges()
    displayed_fps = 0
    frames_accumulated = 0
    fps_last_tick = c.SDL_GetTicksNS()
    past_tick = fps_last_tick

    c.SDL_SetRenderVSync(renderer, 0)
    c.SDL_SetWindowRelativeMouseMode(window, true)
    c.SDL_SetHintWithPriority(c"SDL_WINDOWS_RAW_KEYBOARD", c"1", c.SDL_HintPriority.SDL_HINT_OVERRIDE)

    while pump_events():
        let now = c.SDL_GetTicksNS()
        let dt_ns = now - past_tick

        update_players(dt_ns)
        render_frame()

        if now - fps_last_tick > 999999999:
            displayed_fps = frames_accumulated
            frames_accumulated = 0
            fps_last_tick = now

        past_tick = now
        frames_accumulated += 1

        let elapsed = c.SDL_GetTicksNS() - now
        if elapsed < frame_ns:
            c.SDL_DelayNS(frame_ns - elapsed)

    return 0


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    return c.SDL_RunApp(argc, argv, app_main, null)
