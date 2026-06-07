import std.c.glfw as glfw_raw
import examples.raylib.others.rlgl_loader as rlgl_loader
import std.glfw as glfw
import std.raylib as rl
import std.raymath as rm
import std.rlgl as rlgl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const DEG_TO_RAD: float = rl.PI / 180.0
const RED: rl.Color = rl.Color(r = 230, g = 41, b = 55, a = 255)
const RAYWHITE: rl.Color = rl.Color(r = 245, g = 245, b = 245, a = 255)
const DARKGRAY: rl.Color = rl.Color(r = 80, g = 80, b = 80, a = 255)


function matrix_to_rlgl(matrix: rl.Matrix) -> rlgl.Matrix:
    return rlgl.Matrix(
        m0 = matrix.m0,
        m4 = matrix.m4,
        m8 = matrix.m8,
        m12 = matrix.m12,
        m1 = matrix.m1,
        m5 = matrix.m5,
        m9 = matrix.m9,
        m13 = matrix.m13,
        m2 = matrix.m2,
        m6 = matrix.m6,
        m10 = matrix.m10,
        m14 = matrix.m14,
        m3 = matrix.m3,
        m7 = matrix.m7,
        m11 = matrix.m11,
        m15 = matrix.m15
    )


function load_gl_proc(proc_name: cstr) -> ptr[void]:
    let proc_address = glfw_raw.glfwGetProcAddress(proc_name) else:
        return zero[ptr[void]]
    return unsafe: ptr[void]<-proc_address


function draw_rectangle_v(position: rl.Vector2, size: rl.Vector2, color: rl.Color) -> void:
    rlgl.begin(rlgl.RL_TRIANGLES)
    rlgl.color4ub(color.r, color.g, color.b, color.a)

    rlgl.vertex2f(position.x, position.y)
    rlgl.vertex2f(position.x, position.y + size.y)
    rlgl.vertex2f(position.x + size.x, position.y + size.y)

    rlgl.vertex2f(position.x, position.y)
    rlgl.vertex2f(position.x + size.x, position.y + size.y)
    rlgl.vertex2f(position.x + size.x, position.y)
    rlgl.end()


function draw_grid(slices: int, spacing: float) -> void:
    let half_slices = slices / 2

    rlgl.begin(rlgl.RL_LINES)
    var index = -half_slices
    while index <= half_slices:
        let line_color: float = if index == 0: 0.5 else: 0.75

        rlgl.color3f(line_color, line_color, line_color)
        rlgl.vertex3f(float<-index * spacing, 0.0, float<-(-half_slices) * spacing)
        rlgl.color3f(line_color, line_color, line_color)
        rlgl.vertex3f(float<-index * spacing, 0.0, float<-half_slices * spacing)

        rlgl.color3f(line_color, line_color, line_color)
        rlgl.vertex3f(float<-(-half_slices) * spacing, 0.0, float<-index * spacing)
        rlgl.color3f(line_color, line_color, line_color)
        rlgl.vertex3f(float<-half_slices * spacing, 0.0, float<-index * spacing)

        index += 1
    rlgl.end()


function draw_cube(position: rl.Vector3, width: float, height: float, length: float, color: rl.Color) -> void:
    let half_width = width / 2.0
    let half_height = height / 2.0
    let half_length = length / 2.0

    rlgl.push_matrix()
    rlgl.translatef(position.x, position.y, position.z)
    rlgl.begin(rlgl.RL_TRIANGLES)
    rlgl.color4ub(color.r, color.g, color.b, color.a)

    rlgl.vertex3f(-half_width, -half_height, half_length)
    rlgl.vertex3f(half_width, -half_height, half_length)
    rlgl.vertex3f(-half_width, half_height, half_length)
    rlgl.vertex3f(half_width, half_height, half_length)
    rlgl.vertex3f(-half_width, half_height, half_length)
    rlgl.vertex3f(half_width, -half_height, half_length)

    rlgl.vertex3f(-half_width, -half_height, -half_length)
    rlgl.vertex3f(-half_width, half_height, -half_length)
    rlgl.vertex3f(half_width, -half_height, -half_length)
    rlgl.vertex3f(half_width, half_height, -half_length)
    rlgl.vertex3f(half_width, -half_height, -half_length)
    rlgl.vertex3f(-half_width, half_height, -half_length)

    rlgl.vertex3f(-half_width, half_height, -half_length)
    rlgl.vertex3f(-half_width, half_height, half_length)
    rlgl.vertex3f(half_width, half_height, half_length)
    rlgl.vertex3f(half_width, half_height, -half_length)
    rlgl.vertex3f(-half_width, half_height, -half_length)
    rlgl.vertex3f(half_width, half_height, half_length)

    rlgl.vertex3f(-half_width, -half_height, -half_length)
    rlgl.vertex3f(half_width, -half_height, half_length)
    rlgl.vertex3f(-half_width, -half_height, half_length)
    rlgl.vertex3f(half_width, -half_height, -half_length)
    rlgl.vertex3f(half_width, -half_height, half_length)
    rlgl.vertex3f(-half_width, -half_height, -half_length)

    rlgl.vertex3f(half_width, -half_height, -half_length)
    rlgl.vertex3f(half_width, half_height, -half_length)
    rlgl.vertex3f(half_width, half_height, half_length)
    rlgl.vertex3f(half_width, -half_height, half_length)
    rlgl.vertex3f(half_width, -half_height, -half_length)
    rlgl.vertex3f(half_width, half_height, half_length)

    rlgl.vertex3f(-half_width, -half_height, -half_length)
    rlgl.vertex3f(-half_width, half_height, half_length)
    rlgl.vertex3f(-half_width, half_height, -half_length)
    rlgl.vertex3f(-half_width, -half_height, half_length)
    rlgl.vertex3f(-half_width, half_height, half_length)
    rlgl.vertex3f(-half_width, -half_height, -half_length)
    rlgl.end()
    rlgl.pop_matrix()


function draw_cube_wires(position: rl.Vector3, width: float, height: float, length: float, color: rl.Color) -> void:
    let half_width = width / 2.0
    let half_height = height / 2.0
    let half_length = length / 2.0

    rlgl.push_matrix()
    rlgl.translatef(position.x, position.y, position.z)
    rlgl.begin(rlgl.RL_LINES)
    rlgl.color4ub(color.r, color.g, color.b, color.a)

    rlgl.vertex3f(-half_width, -half_height, half_length)
    rlgl.vertex3f(half_width, -half_height, half_length)
    rlgl.vertex3f(half_width, -half_height, half_length)
    rlgl.vertex3f(half_width, half_height, half_length)
    rlgl.vertex3f(half_width, half_height, half_length)
    rlgl.vertex3f(-half_width, half_height, half_length)
    rlgl.vertex3f(-half_width, half_height, half_length)
    rlgl.vertex3f(-half_width, -half_height, half_length)

    rlgl.vertex3f(-half_width, -half_height, -half_length)
    rlgl.vertex3f(half_width, -half_height, -half_length)
    rlgl.vertex3f(half_width, -half_height, -half_length)
    rlgl.vertex3f(half_width, half_height, -half_length)
    rlgl.vertex3f(half_width, half_height, -half_length)
    rlgl.vertex3f(-half_width, half_height, -half_length)
    rlgl.vertex3f(-half_width, half_height, -half_length)
    rlgl.vertex3f(-half_width, -half_height, -half_length)

    rlgl.vertex3f(-half_width, half_height, half_length)
    rlgl.vertex3f(-half_width, half_height, -half_length)
    rlgl.vertex3f(half_width, half_height, half_length)
    rlgl.vertex3f(half_width, half_height, -half_length)
    rlgl.vertex3f(-half_width, -half_height, half_length)
    rlgl.vertex3f(-half_width, -half_height, -half_length)
    rlgl.vertex3f(half_width, -half_height, half_length)
    rlgl.vertex3f(half_width, -half_height, -half_length)
    rlgl.end()
    rlgl.pop_matrix()


function main() -> int:
    if not glfw.init():
        return 1
    defer glfw.terminate()

    glfw.window_hint(glfw.SAMPLES, 4)
    glfw.window_hint(glfw.DEPTH_BITS, 16)
    glfw.window_hint(glfw.CONTEXT_VERSION_MAJOR, 3)
    glfw.window_hint(glfw.CONTEXT_VERSION_MINOR, 3)
    glfw.window_hint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)

    let window = glfw.create_window(
        SCREEN_WIDTH,
        SCREEN_HEIGHT,
        "raylib [others] example - rlgl standalone",
        null,
        null
    ) else:
        return 2
    defer glfw.destroy_window(window)

    glfw.set_window_pos(window, 200, 200)
    glfw.make_context_current(window)
    glfw.swap_interval(0)

    rlgl_loader.rlLoadExtensions(load_gl_proc)
    rlgl.gl_init(SCREEN_WIDTH, SCREEN_HEIGHT)
    defer rlgl.gl_close()

    rlgl.viewport(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT)
    rlgl.matrix_mode(rlgl.RL_PROJECTION)
    rlgl.load_identity()
    rlgl.ortho(0.0, double<-SCREEN_WIDTH, double<-SCREEN_HEIGHT, 0.0, 0.0, 1.0)
    rlgl.matrix_mode(rlgl.RL_MODELVIEW)
    rlgl.load_identity()

    rlgl.clear_color(245, 245, 245, 255)
    rlgl.enable_depth_test()

    let camera = rl.Camera3D(
        position = rl.Vector3(x = 5.0, y = 5.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )
    let cube_position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    while not glfw.window_should_close(window):
        if glfw.get_key(window, glfw.KEY_ESCAPE) == glfw.PRESS:
            glfw.set_window_should_close(window, glfw.TRUE)

        rlgl.clear_screen_buffers()

        let projection = rm.matrix_perspective(
            double<-(camera.fovy * DEG_TO_RAD),
            (double<-SCREEN_WIDTH) / (double<-SCREEN_HEIGHT),
            0.01,
            1000.0
        )
        let view = rm.matrix_look_at(camera.position, camera.target, camera.up)
        rlgl.set_matrix_modelview(matrix_to_rlgl(view))
        rlgl.set_matrix_projection(matrix_to_rlgl(projection))

        draw_cube(cube_position, 2.0, 2.0, 2.0, RED)
        draw_cube_wires(cube_position, 2.0, 2.0, 2.0, RAYWHITE)
        draw_grid(10, 1.0)
        rlgl.draw_render_batch_active()

        rlgl.set_matrix_modelview(matrix_to_rlgl(rm.matrix_identity()))
        rlgl.set_matrix_projection(
            matrix_to_rlgl(rm.matrix_ortho(0.0, double<-SCREEN_WIDTH, double<-SCREEN_HEIGHT, 0.0, 0.0, 1.0))
        )
        draw_rectangle_v(rl.Vector2(x = 10.0, y = 10.0), rl.Vector2(x = 780.0, y = 20.0), DARKGRAY)
        rlgl.draw_render_batch_active()

        glfw.swap_buffers(window)
        glfw.poll_events()

    return 0
