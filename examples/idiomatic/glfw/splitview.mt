module examples.idiomatic.glfw.splitview

import std.glfw as glfw
import std.gl as gl
import std.c.libm as math

type Vec3 = array[float, 3]
type Mat4 = array[float, 16]

const window_width: int = 500
const window_height: int = 500
const window_title: cstr = c"Split view demo"
const torus_major: float = 1.5
const torus_minor: float = 0.5
const torus_major_res: int = 32
const torus_minor_res: int = 32

var cursor_x: double = 0.0
var cursor_y: double = 0.0
var width: int = window_width
var height: int = window_height
var active_view: int = 0
var rot_x: int = 0
var rot_y: int = 0
var rot_z: int = 0
var do_redraw: bool = true
var torus_list: uint = 0


def vec3_sub(lhs: Vec3, rhs: Vec3) -> Vec3:
    return array[float, 3](
        lhs[0] - rhs[0],
        lhs[1] - rhs[1],
        lhs[2] - rhs[2],
    )


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
    return array[float, 3](
        vector[0] / length,
        vector[1] / length,
        vector[2] / length,
    )


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


def draw_torus() -> void:
    if torus_list == 0:
        torus_list = gl.gen_lists(1)
        gl.new_list(torus_list, uint<-gl.COMPILE_AND_EXECUTE)

        let two_pi = 2.0 * math.M_PI_F
        var i = 0
        while i < torus_minor_res:
            gl.begin(uint<-gl.QUAD_STRIP)

            var j = 0
            while j <= torus_major_res:
                var k = 1
                while k >= 0:
                    let s = float<-((i + k) % torus_minor_res) + 0.5
                    let t = float<-(j % torus_major_res)
                    let tube_angle = s * two_pi / float<-torus_minor_res
                    let ring_angle = t * two_pi / float<-torus_major_res
                    let cos_tube = math.cosf(tube_angle)
                    let sin_tube = math.sinf(tube_angle)
                    let cos_ring = math.cosf(ring_angle)
                    let sin_ring = math.sinf(ring_angle)

                    let x = (torus_major + torus_minor * cos_tube) * cos_ring
                    let y = torus_minor * sin_tube
                    let z = (torus_major + torus_minor * cos_tube) * sin_ring

                    var nx = x - torus_major * cos_ring
                    var ny = y
                    var nz = z - torus_major * sin_ring
                    let normal_scale = 1.0 / math.sqrtf(nx * nx + ny * ny + nz * nz)
                    nx *= normal_scale
                    ny *= normal_scale
                    nz *= normal_scale

                    gl.normal_3f(nx, ny, nz)
                    gl.vertex_3f(x, y, z)
                    k -= 1
                j += 1

            gl.end()
            i += 1

        gl.end_list()
        return

    gl.call_list(torus_list)


def draw_scene() -> void:
    var model_diffuse = array[float, 4](1.0, 0.8, 0.8, 1.0)
    var model_specular = array[float, 4](0.6, 0.6, 0.6, 1.0)

    gl.push_matrix()
    gl.rotatef(float<-rot_x * 0.5, 1.0, 0.0, 0.0)
    gl.rotatef(float<-rot_y * 0.5, 0.0, 1.0, 0.0)
    gl.rotatef(float<-rot_z * 0.5, 0.0, 0.0, 1.0)
    gl.color_4fv(const_ptr_of(model_diffuse[0]))
    gl.materialfv(uint<-gl.FRONT, uint<-gl.DIFFUSE, const_ptr_of(model_diffuse[0]))
    gl.materialfv(uint<-gl.FRONT, uint<-gl.SPECULAR, const_ptr_of(model_specular[0]))
    gl.materialf(uint<-gl.FRONT, uint<-gl.SHININESS, 20.0)
    draw_torus()
    gl.pop_matrix()


def draw_grid(scale: float, steps: int) -> void:
    gl.push_matrix()
    gl.clear_color(0.05, 0.05, 0.2, 0.0)
    gl.clear(uint<-gl.COLOR_BUFFER_BIT)
    load_matrix(mat4_look_at(
        array[float, 3](0.0, 0.0, 1.0),
        array[float, 3](0.0, 0.0, 0.0),
        array[float, 3](0.0, 1.0, 0.0),
    ))
    gl.depth_mask(ubyte<-gl.FALSE)
    gl.color_3f(0.0, 0.5, 0.5)
    gl.begin(uint<-gl.LINES)

    let half_span = scale * 0.5 * float<-(steps - 1)
    var x = half_span
    var y = -half_span
    var index = 0
    while index < steps:
        gl.vertex_3f(-x, y, 0.0)
        gl.vertex_3f(x, y, 0.0)
        y += scale
        index += 1

    x = -half_span
    y = half_span
    index = 0
    while index < steps:
        gl.vertex_3f(x, -y, 0.0)
        gl.vertex_3f(x, y, 0.0)
        x += scale
        index += 1

    gl.end()
    gl.depth_mask(ubyte<-gl.TRUE)
    gl.pop_matrix()


def draw_all_views() -> void:
    var light_position = array[float, 4](0.0, 8.0, 8.0, 1.0)
    var light_diffuse = array[float, 4](1.0, 1.0, 1.0, 1.0)
    var light_specular = array[float, 4](1.0, 1.0, 1.0, 1.0)
    var light_ambient = array[float, 4](0.2, 0.2, 0.3, 1.0)

    var aspect: float = 1.0
    if height > 0:
        aspect = float<-width / float<-height

    gl.clear_color(0.0, 0.0, 0.0, 0.0)
    gl.clear(uint<-(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT))
    gl.enable(uint<-gl.SCISSOR_TEST)
    gl.enable(uint<-gl.DEPTH_TEST)
    gl.depth_func(uint<-gl.LEQUAL)

    gl.polygon_mode(uint<-gl.FRONT_AND_BACK, uint<-gl.LINE)
    gl.enable(uint<-gl.LINE_SMOOTH)
    gl.enable(uint<-gl.BLEND)
    gl.blend_func(uint<-gl.SRC_ALPHA, uint<-gl.ONE_MINUS_SRC_ALPHA)

    gl.matrix_mode(uint<-gl.PROJECTION)
    gl.load_identity()
    gl.ortho(-double<-(3.0 * aspect), double<-(3.0 * aspect), double<-(-3.0), double<-3.0, double<-1.0, double<-50.0)

    gl.viewport(0, height / 2, width / 2, height / 2)
    gl.scissor(0, height / 2, width / 2, height / 2)
    gl.matrix_mode(uint<-gl.MODELVIEW)
    load_matrix(mat4_look_at(
        array[float, 3](0.0, 10.0, 0.001),
        array[float, 3](0.0, 0.0, 0.0),
        array[float, 3](0.0, 1.0, 0.0),
    ))
    draw_grid(0.5, 12)
    draw_scene()

    gl.viewport(0, 0, width / 2, height / 2)
    gl.scissor(0, 0, width / 2, height / 2)
    gl.matrix_mode(uint<-gl.MODELVIEW)
    load_matrix(mat4_look_at(
        array[float, 3](0.0, 0.0, 10.0),
        array[float, 3](0.0, 0.0, 0.0),
        array[float, 3](0.0, 1.0, 0.0),
    ))
    draw_grid(0.5, 12)
    draw_scene()

    gl.viewport(width / 2, 0, width / 2, height / 2)
    gl.scissor(width / 2, 0, width / 2, height / 2)
    gl.matrix_mode(uint<-gl.MODELVIEW)
    load_matrix(mat4_look_at(
        array[float, 3](10.0, 0.0, 0.0),
        array[float, 3](0.0, 0.0, 0.0),
        array[float, 3](0.0, 1.0, 0.0),
    ))
    draw_grid(0.5, 12)
    draw_scene()

    gl.disable(uint<-gl.LINE_SMOOTH)
    gl.disable(uint<-gl.BLEND)

    gl.polygon_mode(uint<-gl.FRONT_AND_BACK, uint<-gl.FILL)
    gl.enable(uint<-gl.CULL_FACE)
    gl.cull_face(uint<-gl.BACK)
    gl.front_face(uint<-gl.CW)

    gl.matrix_mode(uint<-gl.PROJECTION)
    load_matrix(mat4_perspective(65.0 * math.M_PI_F / 180.0, aspect, 1.0, 50.0))

    gl.viewport(width / 2, height / 2, width / 2, height / 2)
    gl.scissor(width / 2, height / 2, width / 2, height / 2)
    gl.matrix_mode(uint<-gl.MODELVIEW)
    load_matrix(mat4_look_at(
        array[float, 3](3.0, 1.5, 3.0),
        array[float, 3](0.0, 0.0, 0.0),
        array[float, 3](0.0, 1.0, 0.0),
    ))

    gl.lightfv(uint<-gl.LIGHT1, uint<-gl.POSITION, const_ptr_of(light_position[0]))
    gl.lightfv(uint<-gl.LIGHT1, uint<-gl.AMBIENT, const_ptr_of(light_ambient[0]))
    gl.lightfv(uint<-gl.LIGHT1, uint<-gl.DIFFUSE, const_ptr_of(light_diffuse[0]))
    gl.lightfv(uint<-gl.LIGHT1, uint<-gl.SPECULAR, const_ptr_of(light_specular[0]))
    gl.enable(uint<-gl.LIGHT1)
    gl.enable(uint<-gl.LIGHTING)
    draw_scene()
    gl.disable(uint<-gl.LIGHTING)

    gl.disable(uint<-gl.CULL_FACE)
    gl.disable(uint<-gl.DEPTH_TEST)
    gl.disable(uint<-gl.SCISSOR_TEST)

    if active_view > 0 and active_view != 2:
        gl.viewport(0, 0, width, height)
        gl.matrix_mode(uint<-gl.PROJECTION)
        gl.load_identity()
        gl.ortho(double<-0.0, double<-2.0, double<-0.0, double<-2.0, double<-0.0, double<-1.0)
        gl.matrix_mode(uint<-gl.MODELVIEW)
        gl.load_identity()
        gl.translatef(float<-((active_view - 1) & 1), float<-(1 - (active_view - 1) / 2), 0.0)
        gl.color_3f(1.0, 1.0, 0.6)
        gl.begin(uint<-gl.LINE_STRIP)
        gl.vertex_2i(0, 0)
        gl.vertex_2i(1, 0)
        gl.vertex_2i(1, 1)
        gl.vertex_2i(0, 1)
        gl.vertex_2i(0, 0)
        gl.end()


def framebuffer_size_callback(window: ptr[glfw.GLFWwindow], w: int, h: int) -> void:
    width = w
    if h > 0:
        height = h
    else:
        height = 1
    do_redraw = true


def window_refresh_callback(window: ptr[glfw.GLFWwindow]) -> void:
    draw_all_views()
    glfw.swap_buffers(window)
    do_redraw = false


def cursor_pos_callback(window: ptr[glfw.GLFWwindow], x: double, y: double) -> void:
    var wnd_width = 0
    var wnd_height = 0
    var fb_width = 0
    var fb_height = 0
    glfw.get_window_size(window, ptr_of(wnd_width), ptr_of(wnd_height))
    glfw.get_framebuffer_size(window, ptr_of(fb_width), ptr_of(fb_height))
    if wnd_width <= 0:
        return

    let scale = double<-fb_width / double<-wnd_width
    let scaled_x = x * scale
    let scaled_y = y * scale

    if active_view == 1:
        rot_x += int<-(scaled_y - cursor_y)
        rot_z += int<-(scaled_x - cursor_x)
        do_redraw = true

    if active_view == 3:
        rot_x += int<-(scaled_y - cursor_y)
        rot_y += int<-(scaled_x - cursor_x)
        do_redraw = true

    if active_view == 4:
        rot_y += int<-(scaled_x - cursor_x)
        rot_z += int<-(scaled_y - cursor_y)
        do_redraw = true

    cursor_x = scaled_x
    cursor_y = scaled_y


def mouse_button_callback(window: ptr[glfw.GLFWwindow], button: int, action: int, mods: int) -> void:
    if button == glfw.MOUSE_BUTTON_1:
        if action == glfw.PRESS:
            active_view = 1
            if cursor_x >= double<-(width / 2):
                active_view += 1
            if cursor_y >= double<-(height / 2):
                active_view += 2
        else:
            active_view = 0
    do_redraw = true


def key_callback(window: ptr[glfw.GLFWwindow], key: int, scancode: int, action: int, mods: int) -> void:
    if key == glfw.KEY_ESCAPE and action == glfw.PRESS:
        glfw.set_window_should_close(window, glfw.TRUE)


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    if glfw.init() == 0:
        return 1
    defer glfw.terminate()

    glfw.window_hint(glfw.SAMPLES, 4)

    let window = glfw.create_window(window_width, window_height, window_title, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.destroy_window(window)

    glfw.set_framebuffer_size_callback(window, framebuffer_size_callback)
    glfw.set_window_refresh_callback(window, window_refresh_callback)
    glfw.set_cursor_pos_callback(window, cursor_pos_callback)
    glfw.set_mouse_button_callback(window, mouse_button_callback)
    glfw.set_key_callback(window, key_callback)

    glfw.make_context_current(window)
    gl.use_glfw_loader()
    glfw.swap_interval(1)
    gl.enable(uint<-gl.MULTISAMPLE)

    glfw.get_framebuffer_size(window, ptr_of(width), ptr_of(height))
    framebuffer_size_callback(window, width, height)

    while true:
        if do_redraw:
            window_refresh_callback(window)

        glfw.wait_events()

        if glfw.window_should_close(window) != 0:
            break

    return 0
