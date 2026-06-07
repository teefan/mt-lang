import std.gl as gl
import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as rm
import std.rlgl as rlgl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330
const MAX_PARTICLES: int = 1000

struct Particle:
    x: float
    y: float
    period: float


function matrix_from_rlgl(matrix: rlgl.Matrix) -> rl.Matrix:
    return rl.Matrix(
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
        m15 = matrix.m15,
    )


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [others] example - OpenGL interoperatibility")
    defer rl.close_window()

    gl.use_raylib_loader()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let shader = rl.load_shader(
        rl.text_format("shaders/glsl%i/point_particle.vs", GLSL_VERSION),
        rl.text_format("shaders/glsl%i/point_particle.fs", GLSL_VERSION),
    )
    defer rl.unload_shader(shader)

    let current_time_location = rl.get_shader_location(shader, "currentTime")
    let color_location = rl.get_shader_location(shader, "color")
    let vertex_position_location = unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_VERTEX_POSITION]
    let matrix_mvp_location = unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_MATRIX_MVP]

    var particles: array[Particle, MAX_PARTICLES] = zero[array[Particle, MAX_PARTICLES]]
    var index = 0
    while index < MAX_PARTICLES:
        particles[index] = Particle(
            x = float<-rl.get_random_value(20, SCREEN_WIDTH - 20),
            y = float<-rl.get_random_value(50, SCREEN_HEIGHT - 20),
            period = float<-rl.get_random_value(10, 30) / 10.0,
        )
        index += 1

    var vao: uint = 0
    var vbo: uint = 0
    defer:
        if vbo != 0:
            gl.delete_buffer_short(1, ptr_of(vbo))
        if vao != 0:
            gl.delete_vertex_arrays(1, ptr_of(vao))

    gl.gen_vertex_arrays(1, ptr_of(vao))
    gl.bind_vertex_array(vao)
    gl.gen_buffer_short(1, ptr_of(vbo))
    gl.bind_buffer(uint<-gl.ARRAY_BUFFER, vbo)
    gl.buffer_data(
        uint<-gl.ARRAY_BUFFER,
        ptr_int<-(MAX_PARTICLES * int<-size_of(Particle)),
        unsafe: ptr[void]<-ptr_of(particles[0]),
        uint<-gl.STATIC_DRAW,
    )
    gl.vertex_attrib_pointer(
        uint<-vertex_position_location,
        3,
        uint<-gl.FLOAT,
        ubyte<-gl.FALSE,
        0,
        zero[const_ptr[void]],
    )
    gl.enable_vertex_attrib_array(uint<-vertex_position_location)
    gl.bind_buffer(uint<-gl.ARRAY_BUFFER, 0)
    gl.bind_vertex_array(0)

    gl.enable(uint<-gl.PROGRAM_POINT_SIZE)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let particle_color = rl.color_normalize(rl.Color(r = 255, g = 0, b = 0, a = 128))
        var color_values = array[float, 4](particle_color.x, particle_color.y, particle_color.z, particle_color.w)
        let model_view_projection = rm.matrix_multiply(
            matrix_from_rlgl(rlgl.get_matrix_modelview()),
            matrix_from_rlgl(rlgl.get_matrix_projection()),
        )
        var mvp_values = rm.matrix_to_float_v(model_view_projection)

        rl.begin_drawing()
        rl.clear_background(rl.WHITE)

        rl.draw_rectangle(10, 10, 210, 30, rl.MAROON)
        rl.draw_text(rl.text_format("%i particles in one vertex buffer", MAX_PARTICLES), 20, 20, 10, rl.RAYWHITE)

        rlgl.draw_render_batch_active()

        gl.use_program(shader.id)
        gl.uniform_1_float(current_time_location, float<-rl.get_time())
        gl.uniform_4_float_values(color_location, 1, ptr_of(color_values[0]))
        gl.uniform_matrix_4_float_values(matrix_mvp_location, 1, ubyte<-gl.FALSE, ptr_of(mvp_values[0]))
        gl.bind_vertex_array(vao)
        gl.draw_arrays(uint<-gl.POINTS, 0, MAX_PARTICLES)
        gl.bind_vertex_array(0)
        gl.use_program(0)

        rl.draw_fps(SCREEN_WIDTH - 100, 10)
        rl.end_drawing()

    return 0
