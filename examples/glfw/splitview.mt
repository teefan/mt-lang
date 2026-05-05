module examples.glfw.splitview

import std.c.glfw as glfw
import std.c.gl as gl
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
    gl.glLoadMatrixf(const_ptr_of(copy[0]))


def draw_torus() -> void:
    if torus_list == 0:
        torus_list = gl.glGenLists(1)
        gl.glNewList(torus_list, uint<-gl.GL_COMPILE_AND_EXECUTE)

        let two_pi = 2.0 * math.M_PI_F
        var i = 0
        while i < torus_minor_res:
            gl.glBegin(uint<-gl.GL_QUAD_STRIP)

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

                    gl.glNormal3f(nx, ny, nz)
                    gl.glVertex3f(x, y, z)
                    k -= 1
                j += 1

            gl.glEnd()
            i += 1

        gl.glEndList()
        return

    gl.glCallList(torus_list)


def draw_scene() -> void:
    var model_diffuse = array[float, 4](1.0, 0.8, 0.8, 1.0)
    var model_specular = array[float, 4](0.6, 0.6, 0.6, 1.0)

    gl.glPushMatrix()
    gl.glRotatef(float<-rot_x * 0.5, 1.0, 0.0, 0.0)
    gl.glRotatef(float<-rot_y * 0.5, 0.0, 1.0, 0.0)
    gl.glRotatef(float<-rot_z * 0.5, 0.0, 0.0, 1.0)
    gl.glColor4fv(const_ptr_of(model_diffuse[0]))
    gl.glMaterialfv(uint<-gl.GL_FRONT, uint<-gl.GL_DIFFUSE, const_ptr_of(model_diffuse[0]))
    gl.glMaterialfv(uint<-gl.GL_FRONT, uint<-gl.GL_SPECULAR, const_ptr_of(model_specular[0]))
    gl.glMaterialf(uint<-gl.GL_FRONT, uint<-gl.GL_SHININESS, 20.0)
    draw_torus()
    gl.glPopMatrix()


def draw_grid(scale: float, steps: int) -> void:
    gl.glPushMatrix()
    gl.glClearColor(0.05, 0.05, 0.2, 0.0)
    gl.glClear(uint<-gl.GL_COLOR_BUFFER_BIT)
    load_matrix(mat4_look_at(
        array[float, 3](0.0, 0.0, 1.0),
        array[float, 3](0.0, 0.0, 0.0),
        array[float, 3](0.0, 1.0, 0.0),
    ))
    gl.glDepthMask(ubyte<-gl.GL_FALSE)
    gl.glColor3f(0.0, 0.5, 0.5)
    gl.glBegin(uint<-gl.GL_LINES)

    let half_span = scale * 0.5 * float<-(steps - 1)
    var x = half_span
    var y = -half_span
    var index = 0
    while index < steps:
        gl.glVertex3f(-x, y, 0.0)
        gl.glVertex3f(x, y, 0.0)
        y += scale
        index += 1

    x = -half_span
    y = half_span
    index = 0
    while index < steps:
        gl.glVertex3f(x, -y, 0.0)
        gl.glVertex3f(x, y, 0.0)
        x += scale
        index += 1

    gl.glEnd()
    gl.glDepthMask(ubyte<-gl.GL_TRUE)
    gl.glPopMatrix()


def draw_all_views() -> void:
    var light_position = array[float, 4](0.0, 8.0, 8.0, 1.0)
    var light_diffuse = array[float, 4](1.0, 1.0, 1.0, 1.0)
    var light_specular = array[float, 4](1.0, 1.0, 1.0, 1.0)
    var light_ambient = array[float, 4](0.2, 0.2, 0.3, 1.0)

    var aspect: float = 1.0
    if height > 0:
        aspect = float<-width / float<-height

    gl.glClearColor(0.0, 0.0, 0.0, 0.0)
    gl.glClear(uint<-(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT))
    gl.glEnable(uint<-gl.GL_SCISSOR_TEST)
    gl.glEnable(uint<-gl.GL_DEPTH_TEST)
    gl.glDepthFunc(uint<-gl.GL_LEQUAL)

    gl.glPolygonMode(uint<-gl.GL_FRONT_AND_BACK, uint<-gl.GL_LINE)
    gl.glEnable(uint<-gl.GL_LINE_SMOOTH)
    gl.glEnable(uint<-gl.GL_BLEND)
    gl.glBlendFunc(uint<-gl.GL_SRC_ALPHA, uint<-gl.GL_ONE_MINUS_SRC_ALPHA)

    gl.glMatrixMode(uint<-gl.GL_PROJECTION)
    gl.glLoadIdentity()
    gl.glOrtho(-3.0 * aspect, 3.0 * aspect, -3.0, 3.0, 1.0, 50.0)

    gl.glViewport(0, height / 2, width / 2, height / 2)
    gl.glScissor(0, height / 2, width / 2, height / 2)
    gl.glMatrixMode(uint<-gl.GL_MODELVIEW)
    load_matrix(mat4_look_at(
        array[float, 3](0.0, 10.0, 0.001),
        array[float, 3](0.0, 0.0, 0.0),
        array[float, 3](0.0, 1.0, 0.0),
    ))
    draw_grid(0.5, 12)
    draw_scene()

    gl.glViewport(0, 0, width / 2, height / 2)
    gl.glScissor(0, 0, width / 2, height / 2)
    gl.glMatrixMode(uint<-gl.GL_MODELVIEW)
    load_matrix(mat4_look_at(
        array[float, 3](0.0, 0.0, 10.0),
        array[float, 3](0.0, 0.0, 0.0),
        array[float, 3](0.0, 1.0, 0.0),
    ))
    draw_grid(0.5, 12)
    draw_scene()

    gl.glViewport(width / 2, 0, width / 2, height / 2)
    gl.glScissor(width / 2, 0, width / 2, height / 2)
    gl.glMatrixMode(uint<-gl.GL_MODELVIEW)
    load_matrix(mat4_look_at(
        array[float, 3](10.0, 0.0, 0.0),
        array[float, 3](0.0, 0.0, 0.0),
        array[float, 3](0.0, 1.0, 0.0),
    ))
    draw_grid(0.5, 12)
    draw_scene()

    gl.glDisable(uint<-gl.GL_LINE_SMOOTH)
    gl.glDisable(uint<-gl.GL_BLEND)

    gl.glPolygonMode(uint<-gl.GL_FRONT_AND_BACK, uint<-gl.GL_FILL)
    gl.glEnable(uint<-gl.GL_CULL_FACE)
    gl.glCullFace(uint<-gl.GL_BACK)
    gl.glFrontFace(uint<-gl.GL_CW)

    gl.glMatrixMode(uint<-gl.GL_PROJECTION)
    load_matrix(mat4_perspective(65.0 * math.M_PI_F / 180.0, aspect, 1.0, 50.0))

    gl.glViewport(width / 2, height / 2, width / 2, height / 2)
    gl.glScissor(width / 2, height / 2, width / 2, height / 2)
    gl.glMatrixMode(uint<-gl.GL_MODELVIEW)
    load_matrix(mat4_look_at(
        array[float, 3](3.0, 1.5, 3.0),
        array[float, 3](0.0, 0.0, 0.0),
        array[float, 3](0.0, 1.0, 0.0),
    ))

    gl.glLightfv(uint<-gl.GL_LIGHT1, uint<-gl.GL_POSITION, const_ptr_of(light_position[0]))
    gl.glLightfv(uint<-gl.GL_LIGHT1, uint<-gl.GL_AMBIENT, const_ptr_of(light_ambient[0]))
    gl.glLightfv(uint<-gl.GL_LIGHT1, uint<-gl.GL_DIFFUSE, const_ptr_of(light_diffuse[0]))
    gl.glLightfv(uint<-gl.GL_LIGHT1, uint<-gl.GL_SPECULAR, const_ptr_of(light_specular[0]))
    gl.glEnable(uint<-gl.GL_LIGHT1)
    gl.glEnable(uint<-gl.GL_LIGHTING)
    draw_scene()
    gl.glDisable(uint<-gl.GL_LIGHTING)

    gl.glDisable(uint<-gl.GL_CULL_FACE)
    gl.glDisable(uint<-gl.GL_DEPTH_TEST)
    gl.glDisable(uint<-gl.GL_SCISSOR_TEST)

    if active_view > 0 and active_view != 2:
        gl.glViewport(0, 0, width, height)
        gl.glMatrixMode(uint<-gl.GL_PROJECTION)
        gl.glLoadIdentity()
        gl.glOrtho(0.0, 2.0, 0.0, 2.0, 0.0, 1.0)
        gl.glMatrixMode(uint<-gl.GL_MODELVIEW)
        gl.glLoadIdentity()
        gl.glTranslatef(float<-((active_view - 1) & 1), float<-(1 - (active_view - 1) / 2), 0.0)
        gl.glColor3f(1.0, 1.0, 0.6)
        gl.glBegin(uint<-gl.GL_LINE_STRIP)
        gl.glVertex2i(0, 0)
        gl.glVertex2i(1, 0)
        gl.glVertex2i(1, 1)
        gl.glVertex2i(0, 1)
        gl.glVertex2i(0, 0)
        gl.glEnd()


def framebuffer_size_callback(window: ptr[glfw.GLFWwindow], w: int, h: int) -> void:
    width = w
    if h > 0:
        height = h
    else:
        height = 1
    do_redraw = true


def window_refresh_callback(window: ptr[glfw.GLFWwindow]) -> void:
    draw_all_views()
    glfw.glfwSwapBuffers(window)
    do_redraw = false


def cursor_pos_callback(window: ptr[glfw.GLFWwindow], x: double, y: double) -> void:
    var wnd_width = 0
    var wnd_height = 0
    var fb_width = 0
    var fb_height = 0
    glfw.glfwGetWindowSize(window, ptr_of(wnd_width), ptr_of(wnd_height))
    glfw.glfwGetFramebufferSize(window, ptr_of(fb_width), ptr_of(fb_height))
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
    if button == glfw.GLFW_MOUSE_BUTTON_1:
        if action == glfw.GLFW_PRESS:
            active_view = 1
            if cursor_x >= double<-(width / 2):
                active_view += 1
            if cursor_y >= double<-(height / 2):
                active_view += 2
        else:
            active_view = 0
    do_redraw = true


def key_callback(window: ptr[glfw.GLFWwindow], key: int, scancode: int, action: int, mods: int) -> void:
    if key == glfw.GLFW_KEY_ESCAPE and action == glfw.GLFW_PRESS:
        glfw.glfwSetWindowShouldClose(window, glfw.GLFW_TRUE)


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    if glfw.glfwInit() == 0:
        return 1
    defer glfw.glfwTerminate()

    glfw.glfwWindowHint(glfw.GLFW_SAMPLES, 4)

    let window = glfw.glfwCreateWindow(window_width, window_height, window_title, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.glfwDestroyWindow(window)

    glfw.glfwSetFramebufferSizeCallback(window, framebuffer_size_callback)
    glfw.glfwSetWindowRefreshCallback(window, window_refresh_callback)
    glfw.glfwSetCursorPosCallback(window, cursor_pos_callback)
    glfw.glfwSetMouseButtonCallback(window, mouse_button_callback)
    glfw.glfwSetKeyCallback(window, key_callback)

    glfw.glfwMakeContextCurrent(window)
    gl.mt_gl_use_glfw_loader()
    glfw.glfwSwapInterval(1)
    gl.glEnable(uint<-gl.GL_MULTISAMPLE)

    glfw.glfwGetFramebufferSize(window, ptr_of(width), ptr_of(height))
    framebuffer_size_callback(window, width, height)

    while true:
        if do_redraw:
            window_refresh_callback(window)

        glfw.glfwWaitEvents()

        if glfw.glfwWindowShouldClose(window) != 0:
            break

    return 0
