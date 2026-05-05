module examples.idiomatic.glfw.gears

import std.glfw as glfw
import std.gl as gl
import std.c.libm as math

const window_width: int = 300
const window_height: int = 300
const window_title: cstr = c"Gears"
var view_rotx: float = 20.0
var view_roty: float = 30.0
var view_rotz: float = 0.0
var gear1: uint = 0
var gear2: uint = 0
var gear3: uint = 0
var angle: float = 0.0


def gear(inner_radius: float, outer_radius: float, width: float, teeth: int, tooth_depth: float) -> void:
    let r0 = inner_radius
    let r1 = outer_radius - tooth_depth * 0.5
    let r2 = outer_radius + tooth_depth * 0.5
    let da = 2.0 * math.M_PI_F / float<-teeth / 4.0

    gl.shade_model(uint<-gl.FLAT)
    gl.normal_3f(0.0, 0.0, 1.0)

    gl.begin(uint<-gl.QUAD_STRIP)
    var index = 0
    while index <= teeth:
        let gear_angle = float<-index * 2.0 * math.M_PI_F / float<-teeth
        let cos_angle = math.cosf(gear_angle)
        let sin_angle = math.sinf(gear_angle)
        gl.vertex_3f(r0 * cos_angle, r0 * sin_angle, width * 0.5)
        gl.vertex_3f(r1 * cos_angle, r1 * sin_angle, width * 0.5)

        if index < teeth:
            let tooth_angle = gear_angle + 3.0 * da
            gl.vertex_3f(r0 * cos_angle, r0 * sin_angle, width * 0.5)
            gl.vertex_3f(r1 * math.cosf(tooth_angle), r1 * math.sinf(tooth_angle), width * 0.5)

        index += 1
    gl.end()

    gl.begin(uint<-gl.QUADS)
    index = 0
    while index < teeth:
        let gear_angle = float<-index * 2.0 * math.M_PI_F / float<-teeth
        gl.vertex_3f(r1 * math.cosf(gear_angle), r1 * math.sinf(gear_angle), width * 0.5)
        gl.vertex_3f(r2 * math.cosf(gear_angle + da), r2 * math.sinf(gear_angle + da), width * 0.5)
        gl.vertex_3f(r2 * math.cosf(gear_angle + 2.0 * da), r2 * math.sinf(gear_angle + 2.0 * da), width * 0.5)
        gl.vertex_3f(r1 * math.cosf(gear_angle + 3.0 * da), r1 * math.sinf(gear_angle + 3.0 * da), width * 0.5)
        index += 1
    gl.end()

    gl.normal_3f(0.0, 0.0, -1.0)
    gl.begin(uint<-gl.QUAD_STRIP)
    index = 0
    while index <= teeth:
        let gear_angle = float<-index * 2.0 * math.M_PI_F / float<-teeth
        let cos_angle = math.cosf(gear_angle)
        let sin_angle = math.sinf(gear_angle)
        gl.vertex_3f(r1 * cos_angle, r1 * sin_angle, -width * 0.5)
        gl.vertex_3f(r0 * cos_angle, r0 * sin_angle, -width * 0.5)

        if index < teeth:
            let tooth_angle = gear_angle + 3.0 * da
            gl.vertex_3f(r1 * math.cosf(tooth_angle), r1 * math.sinf(tooth_angle), -width * 0.5)
            gl.vertex_3f(r0 * cos_angle, r0 * sin_angle, -width * 0.5)

        index += 1
    gl.end()

    gl.begin(uint<-gl.QUADS)
    index = 0
    while index < teeth:
        let gear_angle = float<-index * 2.0 * math.M_PI_F / float<-teeth
        gl.vertex_3f(r1 * math.cosf(gear_angle + 3.0 * da), r1 * math.sinf(gear_angle + 3.0 * da), -width * 0.5)
        gl.vertex_3f(r2 * math.cosf(gear_angle + 2.0 * da), r2 * math.sinf(gear_angle + 2.0 * da), -width * 0.5)
        gl.vertex_3f(r2 * math.cosf(gear_angle + da), r2 * math.sinf(gear_angle + da), -width * 0.5)
        gl.vertex_3f(r1 * math.cosf(gear_angle), r1 * math.sinf(gear_angle), -width * 0.5)
        index += 1
    gl.end()

    gl.begin(uint<-gl.QUAD_STRIP)
    index = 0
    while index < teeth:
        let gear_angle = float<-index * 2.0 * math.M_PI_F / float<-teeth
        let cos_angle = math.cosf(gear_angle)
        let sin_angle = math.sinf(gear_angle)
        let tooth_angle_a = gear_angle + da
        let tooth_angle_b = gear_angle + 2.0 * da
        let tooth_angle_c = gear_angle + 3.0 * da

        gl.vertex_3f(r1 * cos_angle, r1 * sin_angle, width * 0.5)
        gl.vertex_3f(r1 * cos_angle, r1 * sin_angle, -width * 0.5)

        var u = r2 * math.cosf(tooth_angle_a) - r1 * cos_angle
        var v = r2 * math.sinf(tooth_angle_a) - r1 * sin_angle
        let length = math.sqrtf(u * u + v * v)
        u /= length
        v /= length
        gl.normal_3f(v, -u, 0.0)
        gl.vertex_3f(r2 * math.cosf(tooth_angle_a), r2 * math.sinf(tooth_angle_a), width * 0.5)
        gl.vertex_3f(r2 * math.cosf(tooth_angle_a), r2 * math.sinf(tooth_angle_a), -width * 0.5)

        gl.normal_3f(cos_angle, sin_angle, 0.0)
        gl.vertex_3f(r2 * math.cosf(tooth_angle_b), r2 * math.sinf(tooth_angle_b), width * 0.5)
        gl.vertex_3f(r2 * math.cosf(tooth_angle_b), r2 * math.sinf(tooth_angle_b), -width * 0.5)

        u = r1 * math.cosf(tooth_angle_c) - r2 * math.cosf(tooth_angle_b)
        v = r1 * math.sinf(tooth_angle_c) - r2 * math.sinf(tooth_angle_b)
        gl.normal_3f(v, -u, 0.0)
        gl.vertex_3f(r1 * math.cosf(tooth_angle_c), r1 * math.sinf(tooth_angle_c), width * 0.5)
        gl.vertex_3f(r1 * math.cosf(tooth_angle_c), r1 * math.sinf(tooth_angle_c), -width * 0.5)
        gl.normal_3f(cos_angle, sin_angle, 0.0)

        index += 1

    gl.vertex_3f(r1, 0.0, width * 0.5)
    gl.vertex_3f(r1, 0.0, -width * 0.5)
    gl.end()

    gl.shade_model(uint<-gl.SMOOTH)
    gl.begin(uint<-gl.QUAD_STRIP)
    index = 0
    while index <= teeth:
        let gear_angle = float<-index * 2.0 * math.M_PI_F / float<-teeth
        let cos_angle = math.cosf(gear_angle)
        let sin_angle = math.sinf(gear_angle)
        gl.normal_3f(-cos_angle, -sin_angle, 0.0)
        gl.vertex_3f(r0 * cos_angle, r0 * sin_angle, -width * 0.5)
        gl.vertex_3f(r0 * cos_angle, r0 * sin_angle, width * 0.5)
        index += 1
    gl.end()


def draw() -> void:
    gl.clear_color(0.0, 0.0, 0.0, 0.0)
    gl.clear(uint<-(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT))

    gl.push_matrix()
    gl.rotatef(view_rotx, 1.0, 0.0, 0.0)
    gl.rotatef(view_roty, 0.0, 1.0, 0.0)
    gl.rotatef(view_rotz, 0.0, 0.0, 1.0)

    gl.push_matrix()
    gl.translatef(-3.0, -2.0, 0.0)
    gl.rotatef(angle, 0.0, 0.0, 1.0)
    gl.call_list(gear1)
    gl.pop_matrix()

    gl.push_matrix()
    gl.translatef(3.1, -2.0, 0.0)
    gl.rotatef(-2.0 * angle - 9.0, 0.0, 0.0, 1.0)
    gl.call_list(gear2)
    gl.pop_matrix()

    gl.push_matrix()
    gl.translatef(-3.1, 4.2, 0.0)
    gl.rotatef(-2.0 * angle - 25.0, 0.0, 0.0, 1.0)
    gl.call_list(gear3)
    gl.pop_matrix()

    gl.pop_matrix()


def animate() -> void:
    angle = 100.0 * float<-glfw.get_time()


def key_callback(window: ptr[glfw.GLFWwindow], key: int, scancode: int, action: int, mods: int) -> void:
    if action != glfw.PRESS:
        return

    if key == glfw.KEY_Z:
        if (mods & glfw.MOD_SHIFT) != 0:
            view_rotz -= 5.0
        else:
            view_rotz += 5.0
        return

    if key == glfw.KEY_ESCAPE:
        glfw.set_window_should_close(window, glfw.TRUE)
        return

    if key == glfw.KEY_UP:
        view_rotx += 5.0
        return

    if key == glfw.KEY_DOWN:
        view_rotx -= 5.0
        return

    if key == glfw.KEY_LEFT:
        view_roty += 5.0
        return

    if key == glfw.KEY_RIGHT:
        view_roty -= 5.0


def reshape(window: ptr[glfw.GLFWwindow], width: int, height: int) -> void:
    if width <= 0:
        return

    let aspect = float<-height / float<-width
    let znear = 5.0
    let zfar = 30.0
    let xmax = znear * 0.5

    gl.viewport(0, 0, width, height)
    gl.matrix_mode(uint<-gl.PROJECTION)
    gl.load_identity()
    gl.frustum(-xmax, xmax, -xmax * aspect, xmax * aspect, znear, zfar)
    gl.matrix_mode(uint<-gl.MODELVIEW)
    gl.load_identity()
    gl.translatef(0.0, 0.0, -20.0)


def init() -> void:
    var light_position = array[float, 4](5.0, 5.0, 10.0, 0.0)
    var red = array[float, 4](0.8, 0.1, 0.0, 1.0)
    var green = array[float, 4](0.0, 0.8, 0.2, 1.0)
    var blue = array[float, 4](0.2, 0.2, 1.0, 1.0)

    gl.lightfv(uint<-gl.LIGHT0, uint<-gl.POSITION, const_ptr_of(light_position[0]))
    gl.enable(uint<-gl.CULL_FACE)
    gl.enable(uint<-gl.LIGHTING)
    gl.enable(uint<-gl.LIGHT0)
    gl.enable(uint<-gl.DEPTH_TEST)

    gear1 = gl.gen_lists(1)
    gl.new_list(gear1, uint<-gl.COMPILE)
    gl.materialfv(uint<-gl.FRONT, uint<-gl.AMBIENT_AND_DIFFUSE, const_ptr_of(red[0]))
    gear(1.0, 4.0, 1.0, 20, 0.7)
    gl.end_list()

    gear2 = gl.gen_lists(1)
    gl.new_list(gear2, uint<-gl.COMPILE)
    gl.materialfv(uint<-gl.FRONT, uint<-gl.AMBIENT_AND_DIFFUSE, const_ptr_of(green[0]))
    gear(0.5, 2.0, 2.0, 10, 0.7)
    gl.end_list()

    gear3 = gl.gen_lists(1)
    gl.new_list(gear3, uint<-gl.COMPILE)
    gl.materialfv(uint<-gl.FRONT, uint<-gl.AMBIENT_AND_DIFFUSE, const_ptr_of(blue[0]))
    gear(1.3, 2.0, 0.5, 10, 0.7)
    gl.end_list()

    gl.enable(uint<-gl.NORMALIZE)


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    if glfw.init() == 0:
        return 1
    defer glfw.terminate()

    glfw.window_hint(glfw.DEPTH_BITS, 16)
    glfw.window_hint(glfw.TRANSPARENT_FRAMEBUFFER, glfw.TRUE)

    let window = glfw.create_window(window_width, window_height, window_title, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.destroy_window(window)

    glfw.set_framebuffer_size_callback(window, reshape)
    glfw.set_key_callback(window, key_callback)

    glfw.make_context_current(window)
    gl.use_glfw_loader()
    glfw.swap_interval(1)

    var framebuffer_width = 0
    var framebuffer_height = 0
    glfw.get_framebuffer_size(window, ptr_of(framebuffer_width), ptr_of(framebuffer_height))
    reshape(window, framebuffer_width, framebuffer_height)
    init()

    while glfw.window_should_close(window) == 0:
        draw()
        animate()
        glfw.swap_buffers(window)
        glfw.poll_events()

    return 0
