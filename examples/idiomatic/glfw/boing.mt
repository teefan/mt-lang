module examples.idiomatic.glfw.boing

import std.glfw as glfw
import std.gl as gl
import std.c.libm as math
import std.c.libc as libc

type Vec3 = array[float, 3]
type Mat4 = array[float, 16]

struct Vertex:
    x: float
    y: float
    z: float

const radius: float = 70.0
const step_longitude: float = 22.5
const step_latitude: float = 22.5
const dist_ball: float = radius * 2.0 + radius * 0.1
const view_scene_dist: float = dist_ball * 3.0 + 200.0
const grid_size: float = radius * 4.5
const bounce_height: float = radius * 2.1
const bounce_width: float = radius * 2.1
const shadow_offset_x: float = -20.0
const shadow_offset_y: float = 10.0
const shadow_offset_z: float = 0.0
const wall_l_offset: float = 0.0
const wall_r_offset: float = 5.0
const animation_speed: float = 50.0
const max_delta_t: double = 0.02
const draw_ball: int = 0
const draw_ball_shadow: int = 1
const window_width: int = 400
const window_height: int = 400
const window_title: cstr = c"Boing (classic Amiga demo)"

var windowed_xpos: int = 0
var windowed_ypos: int = 0
var windowed_width: int = window_width
var windowed_height: int = window_height
var width: int = window_width
var height: int = window_height
var deg_rot_y: float = 0.0
var deg_rot_y_inc: float = 2.0
var override_pos: bool = false
var cursor_x: float = 0.0
var cursor_y: float = 0.0
var ball_x: float = -radius
var ball_y: float = -radius
var ball_x_inc: float = 1.0
var ball_y_inc: float = 2.0
var draw_ball_how: int = draw_ball
var t_old: double = 0.0
var dt: double = 0.0
var color_toggle: bool = false


def vec3_sub(lhs: Vec3, rhs: Vec3) -> Vec3:
    return array[float, 3](lhs[0] - rhs[0], lhs[1] - rhs[1], lhs[2] - rhs[2])


def vec3_dot(lhs: Vec3, rhs: Vec3) -> float:
    return lhs[0] * rhs[0] + lhs[1] * rhs[1] + lhs[2] * rhs[2]


def vec3_cross(lhs: Vec3, rhs: Vec3) -> Vec3:
    return array[float, 3](
        lhs[1] * rhs[2] - lhs[2] * rhs[1],
        lhs[2] * rhs[0] - lhs[0] * rhs[2],
        lhs[0] * rhs[1] - lhs[1] * rhs[0],
    )


def vec3_normalize(vector: Vec3) -> Vec3:
    let length = math.sqrtf(vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2])
    return array[float, 3](vector[0] / length, vector[1] / length, vector[2] / length)


def mat4_look_at(eye: Vec3, center: Vec3, up: Vec3) -> Mat4:
    let forward = vec3_normalize(vec3_sub(center, eye))
    let side = vec3_normalize(vec3_cross(forward, up))
    let up_dir = vec3_cross(side, forward)
    return array[float, 16](
        side[0], up_dir[0], -forward[0], 0.0,
        side[1], up_dir[1], -forward[1], 0.0,
        side[2], up_dir[2], -forward[2], 0.0,
        -vec3_dot(side, eye), -vec3_dot(up_dir, eye), vec3_dot(forward, eye), 1.0,
    )


def mat4_perspective(fov_radians: float, aspect: float, near: float, far: float) -> Mat4:
    let focal_length = 1.0 / math.tanf(fov_radians * 0.5)
    return array[float, 16](
        focal_length / aspect, 0.0, 0.0, 0.0,
        0.0, focal_length, 0.0, 0.0,
        0.0, 0.0, (far + near) / (near - far), -1.0,
        0.0, 0.0, (2.0 * far * near) / (near - far), 0.0,
    )


def load_matrix(matrix: Mat4) -> void:
    var copy = matrix
    gl.load_matrixf(const_ptr_of(copy[0]))


def truncate_deg(deg: float) -> float:
    if deg >= 360.0:
        return deg - 360.0
    return deg


def deg2rad(deg: float) -> float:
    return deg / 360.0 * (2.0 * math.M_PI_F)


def sin_deg(deg: float) -> float:
    return math.sinf(deg2rad(deg))


def cos_deg(deg: float) -> float:
    return math.cosf(deg2rad(deg))


def cross_product(a: Vertex, b: Vertex, c: Vertex) -> Vertex:
    let u1 = b.x - a.x
    let u2 = b.y - a.y
    let u3 = b.z - a.z
    let v1 = c.x - a.x
    let v2 = c.y - a.y
    let v3 = c.z - a.z
    return Vertex(
        x = u2 * v3 - v2 * u3,
        y = u3 * v1 - v3 * u1,
        z = u1 * v2 - v1 * u2,
    )


def init() -> void:
    gl.clear_color(0.55, 0.55, 0.55, 0.0)
    gl.shade_model(uint<-gl.FLAT)


def display() -> void:
    gl.clear(uint<-(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT))
    gl.push_matrix()
    draw_ball_how = draw_ball_shadow
    draw_boing_ball()
    draw_grid()
    draw_ball_how = draw_ball
    draw_boing_ball()
    gl.pop_matrix()
    gl.flush()


def reshape(window: ptr[glfw.GLFWwindow], w: int, h: int) -> void:
    width = w
    if h > 0:
        height = h
    else:
        height = 1

    gl.viewport(0, 0, width, height)
    gl.matrix_mode(uint<-gl.PROJECTION)
    let projection = mat4_perspective(
        2.0 * math.atan2f(radius, 200.0),
        float<-width / float<-height,
        1.0,
        view_scene_dist,
    )
    load_matrix(projection)

    gl.matrix_mode(uint<-gl.MODELVIEW)
    let view = mat4_look_at(
        array[float, 3](0.0, 0.0, view_scene_dist),
        array[float, 3](0.0, 0.0, 0.0),
        array[float, 3](0.0, -1.0, 0.0),
    )
    load_matrix(view)


def key_callback(window: ptr[glfw.GLFWwindow], key: int, scancode: int, action: int, mods: int) -> void:
    if action != glfw.PRESS:
        return

    if key == glfw.KEY_ESCAPE and mods == 0:
        glfw.set_window_should_close(window, glfw.TRUE)
        return

    if ((key == glfw.KEY_ENTER and mods == glfw.MOD_ALT) or (key == glfw.KEY_F11 and mods == glfw.MOD_ALT)):
        if glfw.get_window_monitor(window) != zero[ptr[glfw.GLFWmonitor]]:
            glfw.set_window_monitor(window, zero[ptr[glfw.GLFWmonitor]], windowed_xpos, windowed_ypos, windowed_width, windowed_height, 0)
            return

        let monitor = glfw.get_primary_monitor()
        if monitor != zero[ptr[glfw.GLFWmonitor]]:
            let mode_ptr = glfw.get_video_mode(monitor)
            if mode_ptr != zero[const_ptr[glfw.GLFWvidmode]]:
                var mode = zero[glfw.GLFWvidmode]
                unsafe:
                    mode = read(mode_ptr)
                glfw.get_window_pos(window, ptr_of(windowed_xpos), ptr_of(windowed_ypos))
                glfw.get_window_size(window, ptr_of(windowed_width), ptr_of(windowed_height))
                glfw.set_window_monitor(window, monitor, 0, 0, mode.width, mode.height, mode.refreshRate)


def set_ball_pos(x: float, y: float) -> void:
    ball_x = float<-(width / 2) - x
    ball_y = y - float<-(height / 2)


def mouse_button_callback(window: ptr[glfw.GLFWwindow], button: int, action: int, mods: int) -> void:
    if button != glfw.MOUSE_BUTTON_1:
        return

    if action == glfw.PRESS:
        override_pos = true
        set_ball_pos(cursor_x, cursor_y)
        return

    override_pos = false


def cursor_position_callback(window: ptr[glfw.GLFWwindow], x: double, y: double) -> void:
    cursor_x = float<-x
    cursor_y = float<-y
    if override_pos:
        set_ball_pos(cursor_x, cursor_y)


def draw_boing_ball() -> void:
    gl.push_matrix()
    gl.matrix_mode(uint<-gl.MODELVIEW)
    gl.translatef(0.0, 0.0, dist_ball)

    var remaining = dt
    while remaining > 0.0:
        var delta = remaining
        if delta > max_delta_t:
            delta = max_delta_t
        remaining -= delta
        bounce_ball(delta)
        deg_rot_y = truncate_deg(deg_rot_y + deg_rot_y_inc * float<-(delta * float<-animation_speed))

    gl.translatef(ball_x, ball_y, 0.0)
    if draw_ball_how == draw_ball_shadow:
        gl.translatef(shadow_offset_x, shadow_offset_y, shadow_offset_z)

    gl.rotatef(-20.0, 0.0, 0.0, 1.0)
    gl.rotatef(deg_rot_y, 0.0, 1.0, 0.0)
    gl.cull_face(uint<-gl.FRONT)
    gl.enable(uint<-gl.CULL_FACE)
    gl.enable(uint<-gl.NORMALIZE)

    var lon_deg: float = 0.0
    while lon_deg < 180.0:
        draw_boing_ball_band(lon_deg, lon_deg + step_longitude)
        lon_deg += step_longitude

    gl.pop_matrix()


def bounce_ball(delta_t: double) -> void:
    if override_pos:
        return

    if ball_x > (bounce_width * 0.5 + wall_r_offset):
        ball_x_inc = -0.5 - 0.75 * float<-libc.rand() / float<-libc.RAND_MAX
        deg_rot_y_inc = -deg_rot_y_inc

    if ball_x < -(bounce_height * 0.5 + wall_l_offset):
        ball_x_inc = 0.5 + 0.75 * float<-libc.rand() / float<-libc.RAND_MAX
        deg_rot_y_inc = -deg_rot_y_inc

    if ball_y > bounce_height * 0.5:
        ball_y_inc = -0.75 - float<-libc.rand() / float<-libc.RAND_MAX

    if ball_y < -(bounce_height * 0.5 * 0.85):
        ball_y_inc = 0.75 + float<-libc.rand() / float<-libc.RAND_MAX

    ball_x += ball_x_inc * float<-(delta_t * animation_speed)
    ball_y += ball_y_inc * float<-(delta_t * animation_speed)

    var sign: float = 1.0
    if ball_y_inc < 0.0:
        sign = -1.0

    var deg = (ball_y + bounce_height * 0.5) * 90.0 / bounce_height
    if deg > 80.0:
        deg = 80.0
    if deg < 10.0:
        deg = 10.0

    ball_y_inc = sign * 4.0 * sin_deg(deg)


def draw_boing_ball_band(long_lo: float, long_hi: float) -> void:
    var lat_deg: float = 0.0
    while lat_deg <= 360.0 - step_latitude:
        if color_toggle:
            gl.color_3f(0.8, 0.1, 0.1)
        else:
            gl.color_3f(0.95, 0.95, 0.95)
        color_toggle = not color_toggle

        if draw_ball_how == draw_ball_shadow:
            gl.color_3f(0.35, 0.35, 0.35)

        let vert_ne = Vertex(
            x = cos_deg(lat_deg) * (radius * sin_deg(long_lo + step_longitude)),
            y = cos_deg(long_hi) * radius,
            z = sin_deg(lat_deg) * (radius * sin_deg(long_lo + step_longitude)),
        )
        let vert_nw = Vertex(
            x = cos_deg(lat_deg + step_latitude) * (radius * sin_deg(long_lo + step_longitude)),
            y = cos_deg(long_hi) * radius,
            z = sin_deg(lat_deg + step_latitude) * (radius * sin_deg(long_lo + step_longitude)),
        )
        let vert_sw = Vertex(
            x = cos_deg(lat_deg + step_latitude) * (radius * sin_deg(long_lo)),
            y = cos_deg(long_lo) * radius,
            z = sin_deg(lat_deg + step_latitude) * (radius * sin_deg(long_lo)),
        )
        let vert_se = Vertex(
            x = cos_deg(lat_deg) * (radius * sin_deg(long_lo)),
            y = cos_deg(long_lo) * radius,
            z = sin_deg(lat_deg) * (radius * sin_deg(long_lo)),
        )
        let normal = cross_product(vert_ne, vert_nw, vert_sw)

        gl.begin(uint<-gl.POLYGON)
        gl.normal_3f(normal.x, normal.y, normal.z)
        gl.vertex_3f(vert_ne.x, vert_ne.y, vert_ne.z)
        gl.vertex_3f(vert_nw.x, vert_nw.y, vert_nw.z)
        gl.vertex_3f(vert_sw.x, vert_sw.y, vert_sw.z)
        gl.vertex_3f(vert_se.x, vert_se.y, vert_se.z)
        gl.end()

        lat_deg += step_latitude

    color_toggle = not color_toggle


def draw_grid() -> void:
    let row_total = 12
    let col_total = row_total
    let width_line = float<-2.0
    let size_cell = grid_size / float<-row_total
    let z_offset = -float<-40.0
    let half_grid = grid_size * float<-0.5

    gl.push_matrix()
    gl.disable(uint<-gl.CULL_FACE)
    gl.translatef(0.0, 0.0, dist_ball)

    var col = 0
    while col <= col_total:
        let xl = -half_grid + float<-col * size_cell
        let xr = xl + width_line
        let yt = half_grid
        let yb = -half_grid - width_line

        gl.begin(uint<-gl.POLYGON)
        gl.color_3f(0.6, 0.1, 0.6)
        gl.vertex_3f(xr, yt, z_offset)
        gl.vertex_3f(xl, yt, z_offset)
        gl.vertex_3f(xl, yb, z_offset)
        gl.vertex_3f(xr, yb, z_offset)
        gl.end()
        col += 1

    var row = 0
    while row <= row_total:
        let yt = half_grid - float<-row * size_cell
        let yb = yt - width_line
        let xl = -half_grid
        let xr = half_grid + width_line

        gl.begin(uint<-gl.POLYGON)
        gl.color_3f(0.6, 0.1, 0.6)
        gl.vertex_3f(xr, yt, z_offset)
        gl.vertex_3f(xl, yt, z_offset)
        gl.vertex_3f(xl, yb, z_offset)
        gl.vertex_3f(xr, yb, z_offset)
        gl.end()
        row += 1

    gl.pop_matrix()


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    if glfw.init() == 0:
        return 1
    defer glfw.terminate()

    let window = glfw.create_window(window_width, window_height, window_title, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.destroy_window(window)

    glfw.set_window_aspect_ratio(window, 1, 1)
    glfw.set_framebuffer_size_callback(window, reshape)
    glfw.set_key_callback(window, key_callback)
    glfw.set_mouse_button_callback(window, mouse_button_callback)
    glfw.set_cursor_pos_callback(window, cursor_position_callback)

    glfw.make_context_current(window)
    gl.use_glfw_loader()
    glfw.swap_interval(1)

    glfw.get_framebuffer_size(window, ptr_of(width), ptr_of(height))
    reshape(window, width, height)
    glfw.set_time(0.0)
    init()

    while true:
        let now = glfw.get_time()
        dt = now - t_old
        t_old = now

        display()
        glfw.swap_buffers(window)
        glfw.poll_events()

        if glfw.window_should_close(window) != 0:
            break

    return 0
