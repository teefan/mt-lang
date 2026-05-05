module examples.glfw.wave

import std.c.glfw as glfw
import std.c.gl as gl
import std.c.libm as math

struct Vertex:
    x: float
    y: float
    z: float
    r: float
    g: float
    b: float

const max_delta_t: float = 0.01
const animation_speed: float = 10.0
const grid_width: int = 50
const grid_height: int = 50
const vertex_count: int = grid_width * grid_height
const quad_width: int = grid_width - 1
const quad_height: int = grid_height - 1
const quad_count: int = quad_width * quad_height
const quad_index_count: int = 4 * quad_count
const field_of_view_degrees: float = 60.0
const deg_to_rad: float = 0.017453292519943295
const near_plane: float = 1.0
const far_plane: float = 1024.0

var alpha: float = 210.0
var beta: float = -70.0
var zoom: float = 2.0
var cursor_x: double = 0.0
var cursor_y: double = 0.0

var quad_indices: array[uint, quad_index_count] = zero[array[uint, quad_index_count]]
var vertices: array[Vertex, vertex_count] = zero[array[Vertex, vertex_count]]

var pressure: array[array[float, grid_height], grid_width] = zero[array[array[float, grid_height], grid_width]]
var velocity_x: array[array[float, grid_height], grid_width] = zero[array[array[float, grid_height], grid_width]]
var velocity_y: array[array[float, grid_height], grid_width] = zero[array[array[float, grid_height], grid_width]]
var acceleration_x: array[array[float, grid_height], grid_width] = zero[array[array[float, grid_height], grid_width]]
var acceleration_y: array[array[float, grid_height], grid_width] = zero[array[array[float, grid_height], grid_width]]


def grid_index(x: int, y: int) -> int:
    return y * grid_width + x


def init_vertices() -> void:
    var y = 0
    while y < grid_height:
        var x = 0
        while x < grid_width:
            let pos = grid_index(x, y)
            vertices[pos].x = float<-(x - grid_width / 2) / float<-(grid_width / 2)
            vertices[pos].y = float<-(y - grid_height / 2) / float<-(grid_height / 2)
            vertices[pos].z = 0.0

            if (x % 4 < 2) != (y % 4 < 2):
                vertices[pos].r = 0.0
            else:
                vertices[pos].r = 1.0

            vertices[pos].g = float<-y / float<-grid_height
            vertices[pos].b = 1.0 - ((float<-x / float<-grid_width + float<-y / float<-grid_height) / 2.0)
            x += 1
        y += 1

    y = 0
    while y < quad_height:
        var x = 0
        while x < quad_width:
            let pos = 4 * (y * quad_width + x)
            quad_indices[pos + 0] = uint<-grid_index(x, y)
            quad_indices[pos + 1] = uint<-grid_index(x + 1, y)
            quad_indices[pos + 2] = uint<-grid_index(x + 1, y + 1)
            quad_indices[pos + 3] = uint<-grid_index(x, y + 1)
            x += 1
        y += 1


def init_grid() -> void:
    var y = 0
    while y < grid_height:
        var x = 0
        while x < grid_width:
            let dx = float<-(x - grid_width / 2)
            let dy = float<-(y - grid_height / 2)
            let distance = math.sqrtf(dx * dx + dy * dy)
            if distance < 0.1 * float<-(grid_width / 2):
                let phase = distance * (math.M_PI_F / float<-(grid_width * 4))
                pressure[x][y] = -math.cosf(phase) * 100.0
            else:
                pressure[x][y] = 0.0

            velocity_x[x][y] = 0.0
            velocity_y[x][y] = 0.0
            x += 1
        y += 1


def adjust_grid() -> void:
    var y = 0
    while y < grid_height:
        var x = 0
        while x < grid_width:
            let pos = grid_index(x, y)
            vertices[pos].z = pressure[x][y] / 50.0
            x += 1
        y += 1


def calc_grid(time_step: float) -> void:
    var x = 0
    while x < grid_width:
        let next_x = (x + 1) % grid_width
        var y = 0
        while y < grid_height:
            acceleration_x[x][y] = pressure[x][y] - pressure[next_x][y]
            y += 1
        x += 1

    var y = 0
    while y < grid_height:
        let next_y = (y + 1) % grid_height
        x = 0
        while x < grid_width:
            acceleration_y[x][y] = pressure[x][y] - pressure[x][next_y]
            x += 1
        y += 1

    x = 0
    while x < grid_width:
        y = 0
        while y < grid_height:
            velocity_x[x][y] += acceleration_x[x][y] * time_step
            velocity_y[x][y] += acceleration_y[x][y] * time_step
            y += 1
        x += 1

    x = 1
    while x < grid_width:
        let prev_x = x - 1
        y = 1
        while y < grid_height:
            let prev_y = y - 1
            pressure[x][y] += (velocity_x[prev_x][y] - velocity_x[x][y] + velocity_y[x][prev_y] - velocity_y[x][y]) * time_step
            y += 1
        x += 1


def set_projection(width: int, height: int) -> void:
    let safe_height = if height > 0: height else: 1
    let ratio = float<-width / float<-safe_height
    let half_angle = (field_of_view_degrees * 0.5) * deg_to_rad
    let ymax = double<-(near_plane * math.tanf(half_angle))
    let xmax = ymax * double<-ratio

    gl.glViewport(0, 0, width, safe_height)
    gl.glMatrixMode(uint<-gl.GL_PROJECTION)
    gl.glLoadIdentity()
    gl.glFrustum(-xmax, xmax, -ymax, ymax, double<-near_plane, double<-far_plane)


def init_opengl() -> void:
    gl.glShadeModel(uint<-gl.GL_SMOOTH)
    gl.glEnable(uint<-gl.GL_DEPTH_TEST)
    gl.glEnableClientState(uint<-gl.GL_VERTEX_ARRAY)
    gl.glEnableClientState(uint<-gl.GL_COLOR_ARRAY)
    unsafe:
        gl.glVertexPointer(3, uint<-gl.GL_FLOAT, int<-size_of(Vertex), const_ptr[void]<-ptr_of(vertices[0]))
        gl.glColorPointer(3, uint<-gl.GL_FLOAT, int<-size_of(Vertex), const_ptr[void]<-ptr_of(vertices[0].r))
    gl.glPointSize(2.0)
    gl.glClearColor(0.0, 0.0, 0.0, 0.0)


def draw_scene(window: ptr[glfw.GLFWwindow]) -> void:
    gl.glClear(uint<-(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT))
    gl.glMatrixMode(uint<-gl.GL_MODELVIEW)
    gl.glLoadIdentity()
    gl.glTranslatef(0.0, 0.0, -zoom)
    gl.glRotatef(beta, 1.0, 0.0, 0.0)
    gl.glRotatef(alpha, 0.0, 0.0, 1.0)
    unsafe:
        gl.glDrawElements(uint<-gl.GL_QUADS, quad_index_count, uint<-gl.GL_UNSIGNED_INT, const_ptr[void]<-ptr_of(quad_indices[0]))
    glfw.glfwSwapBuffers(window)


def key_callback(window: ptr[glfw.GLFWwindow], key: int, scancode: int, action: int, mods: int) -> void:
    if action != glfw.GLFW_PRESS:
        return

    if key == glfw.GLFW_KEY_ESCAPE:
        glfw.glfwSetWindowShouldClose(window, glfw.GLFW_TRUE)
        return

    if key == glfw.GLFW_KEY_SPACE:
        init_grid()
        adjust_grid()
        return

    if key == glfw.GLFW_KEY_LEFT:
        alpha += 5.0
        return

    if key == glfw.GLFW_KEY_RIGHT:
        alpha -= 5.0
        return

    if key == glfw.GLFW_KEY_UP:
        beta -= 5.0
        return

    if key == glfw.GLFW_KEY_DOWN:
        beta += 5.0
        return

    if key == glfw.GLFW_KEY_PAGE_UP:
        zoom -= 0.25
        if zoom < 0.0:
            zoom = 0.0
        return

    if key == glfw.GLFW_KEY_PAGE_DOWN:
        zoom += 0.25


def mouse_button_callback(window: ptr[glfw.GLFWwindow], button: int, action: int, mods: int) -> void:
    if button != glfw.GLFW_MOUSE_BUTTON_1:
        return

    if action == glfw.GLFW_PRESS:
        glfw.glfwSetInputMode(window, glfw.GLFW_CURSOR, glfw.GLFW_CURSOR_DISABLED)
        glfw.glfwGetCursorPos(window, ptr_of(cursor_x), ptr_of(cursor_y))
    else:
        glfw.glfwSetInputMode(window, glfw.GLFW_CURSOR, glfw.GLFW_CURSOR_NORMAL)


def cursor_position_callback(window: ptr[glfw.GLFWwindow], x: double, y: double) -> void:
    if glfw.glfwGetInputMode(window, glfw.GLFW_CURSOR) == glfw.GLFW_CURSOR_DISABLED:
        alpha += float<-(x - cursor_x) / 10.0
        beta += float<-(y - cursor_y) / 10.0
        cursor_x = x
        cursor_y = y


def scroll_callback(window: ptr[glfw.GLFWwindow], xoffset: double, yoffset: double) -> void:
    zoom += float<-yoffset / 4.0
    if zoom < 0.0:
        zoom = 0.0


def framebuffer_size_callback(window: ptr[glfw.GLFWwindow], width: int, height: int) -> void:
    set_projection(width, height)


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    if glfw.glfwInit() == 0:
        return 1
    defer glfw.glfwTerminate()

    let window = glfw.glfwCreateWindow(640, 480, c"Wave Simulation", zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.glfwDestroyWindow(window)

    glfw.glfwSetKeyCallback(window, key_callback)
    glfw.glfwSetFramebufferSizeCallback(window, framebuffer_size_callback)
    glfw.glfwSetMouseButtonCallback(window, mouse_button_callback)
    glfw.glfwSetCursorPosCallback(window, cursor_position_callback)
    glfw.glfwSetScrollCallback(window, scroll_callback)

    glfw.glfwMakeContextCurrent(window)
    gl.mt_gl_use_glfw_loader()
    glfw.glfwSwapInterval(1)

    var framebuffer_width = 0
    var framebuffer_height = 0
    glfw.glfwGetFramebufferSize(window, ptr_of(framebuffer_width), ptr_of(framebuffer_height))
    framebuffer_size_callback(window, framebuffer_width, framebuffer_height)

    init_vertices()
    init_opengl()
    init_grid()
    adjust_grid()

    var previous_time = glfw.glfwGetTime() - 0.01
    while glfw.glfwWindowShouldClose(window) == 0:
        let now = glfw.glfwGetTime()
        var remaining = float<-(now - previous_time)
        previous_time = now

        while remaining > 0.0:
            let step = if remaining > max_delta_t: max_delta_t else: remaining
            calc_grid(step * animation_speed)
            remaining -= step

        adjust_grid()
        draw_scene(window)
        glfw.glfwPollEvents()

    return 0
