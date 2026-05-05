module examples.idiomatic.sdl3.opengl.triangle

import std.sdl3 as sdl
import std.gl as gl
import std.c.libm as math

type Mat4 = array[float, 16]

const window_width: int = 640
const window_height: int = 480
const window_title: str = "examples/idiomatic/sdl3/opengl/triangle"
const window_flags: ptr_uint = sdl.WINDOW_OPENGL | sdl.WINDOW_RESIZABLE
var positions: array[float, 6] = array[float, 6](
    -0.6, -0.4,
    0.6, -0.4,
    0.0, 0.6,
)
var colors: array[float, 9] = array[float, 9](
    1.0, 0.0, 0.0,
    0.0, 1.0, 0.0,
    0.0, 0.0, 1.0,
)
const vertex_shader_text: cstr = c<<-GLSL
    #version 330
    uniform mat4 MVP;
    in vec3 vCol;
    in vec2 vPos;
    out vec3 color;
    void main()
    {
        gl_Position = MVP * vec4(vPos, 0.0, 1.0);
        color = vCol;
    }
GLSL
const fragment_shader_text: cstr = c<<-GLSL
    #version 330
    in vec3 color;
    out vec4 fragment;
    void main()
    {
        fragment = vec4(color, 1.0);
    }
GLSL


def pump_events() -> bool:
    var event = zero[sdl.Event]

    while sdl.poll_event(out event):
        if event.type_ == uint<-sdl.EventType.SDL_EVENT_QUIT:
            return false

        if event.type_ == uint<-sdl.EventType.SDL_EVENT_WINDOW_CLOSE_REQUESTED:
            return false

        if event.type_ == uint<-sdl.EventType.SDL_EVENT_KEY_DOWN and event.key.scancode == sdl.Scancode.SDL_SCANCODE_ESCAPE and event.key.down:
            return false

    return true


def mat4_ortho(left: float, right: float, bottom: float, top: float, near: float, far: float) -> Mat4:
    return array[float, 16](
        2.0 / (right - left), 0.0, 0.0, 0.0,
        0.0, 2.0 / (top - bottom), 0.0, 0.0,
        0.0, 0.0, -2.0 / (far - near), 0.0,
        -((right + left) / (right - left)), -((top + bottom) / (top - bottom)), -((far + near) / (far - near)), 1.0,
    )


def mat4_rotate_z(angle: float) -> Mat4:
    let cosine = math.cosf(angle)
    let sine = math.sinf(angle)
    return array[float, 16](
        cosine, sine, 0.0, 0.0,
        -sine, cosine, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    )


def mat4_mul(lhs: Mat4, rhs: Mat4) -> Mat4:
    var result = zero[Mat4]
    var column = 0
    while column < 4:
        var row = 0
        while row < 4:
            var value: float = 0.0
            var index = 0
            while index < 4:
                value += lhs[row + index * 4] * rhs[index + column * 4]
                index += 1
            result[row + column * 4] = value
            row += 1
        column += 1
    return result


def build_shader(shader_type: gl.GLenum, source_text: cstr) -> gl.GLuint:
    let shader = gl.create_shader(uint<-shader_type)
    var sources = zero[array[const_ptr[gl.GLchar], 1]]
    var source_ptrs = zero[const_ptr[const_ptr[gl.GLchar]]]
    unsafe:
        sources[0] = const_ptr[gl.GLchar]<-source_text
        source_ptrs = const_ptr[const_ptr[gl.GLchar]]<-ptr_of(sources[0])
    gl.shader_source(shader, 1, source_ptrs, zero[const_ptr[gl.GLint]])
    gl.compile_shader(shader)
    return shader


def app_main(argc: int, argv: ptr[ptr[char]]) -> int:
    if not sdl.set_app_metadata("Example SDL3 OpenGL Triangle", "1.0", "com.example.sdl3-opengl-triangle"):
        return 1

    if not sdl.init(sdl.INIT_VIDEO):
        return 1
    defer sdl.quit()

    if not sdl.gl_set_attribute(sdl.GLAttr.SDL_GL_CONTEXT_MAJOR_VERSION, 3):
        return 1
    if not sdl.gl_set_attribute(sdl.GLAttr.SDL_GL_CONTEXT_MINOR_VERSION, 3):
        return 1
    if not sdl.gl_set_attribute(sdl.GLAttr.SDL_GL_CONTEXT_PROFILE_MASK, sdl.GL_CONTEXT_PROFILE_CORE):
        return 1

    let window = sdl.create_window(window_title, window_width, window_height, window_flags)
    if window == zero[ptr[sdl.Window]]:
        return 1
    defer sdl.destroy_window(window)

    let context = sdl.gl_create_context(window)
    if context == zero[ptr[sdl.GLContextState]]:
        return 1
    defer sdl.gl_destroy_context(context)

    if not sdl.gl_make_current(window, context):
        return 1

    gl.use_sdl_loader()
    defer gl.reset_loader()

    if not sdl.gl_set_swap_interval(1):
        return 1

    var position_buffer: gl.GLuint = 0
    gl.gen_buffers(1, ptr_of(position_buffer))
    gl.bind_buffer(uint<-gl.ARRAY_BUFFER, position_buffer)
    unsafe:
        gl.buffer_data(uint<-gl.ARRAY_BUFFER, ptr_int<-(6 * int<-size_of(float)), const_ptr[void]<-ptr_of(positions[0]), uint<-gl.STATIC_DRAW)

    var color_buffer: gl.GLuint = 0
    gl.gen_buffers(1, ptr_of(color_buffer))
    gl.bind_buffer(uint<-gl.ARRAY_BUFFER, color_buffer)
    unsafe:
        gl.buffer_data(uint<-gl.ARRAY_BUFFER, ptr_int<-(9 * int<-size_of(float)), const_ptr[void]<-ptr_of(colors[0]), uint<-gl.STATIC_DRAW)

    let vertex_shader = build_shader(uint<-gl.VERTEX_SHADER, vertex_shader_text)
    let fragment_shader = build_shader(uint<-gl.FRAGMENT_SHADER, fragment_shader_text)

    let program = gl.create_program()
    gl.attach_shader(program, vertex_shader)
    gl.attach_shader(program, fragment_shader)
    gl.link_program(program)

    var mvp_name = zero[const_ptr[gl.GLchar]]
    var vpos_name = zero[const_ptr[gl.GLchar]]
    var vcol_name = zero[const_ptr[gl.GLchar]]
    unsafe:
        mvp_name = const_ptr[gl.GLchar]<-c"MVP"
        vpos_name = const_ptr[gl.GLchar]<-c"vPos"
        vcol_name = const_ptr[gl.GLchar]<-c"vCol"

    let mvp_location = gl.get_uniform_location(program, mvp_name)
    let vpos_location = gl.get_attrib_location(program, vpos_name)
    let vcol_location = gl.get_attrib_location(program, vcol_name)

    var vertex_array: gl.GLuint = 0
    gl.gen_vertex_arrays(1, ptr_of(vertex_array))
    gl.bind_vertex_array(vertex_array)

    gl.bind_buffer(uint<-gl.ARRAY_BUFFER, position_buffer)
    gl.enable_vertex_attrib_array(uint<-vpos_location)
    gl.vertex_attrib_pointer(uint<-vpos_location, 2, uint<-gl.FLOAT, ubyte<-gl.FALSE, 0, zero[const_ptr[void]])

    gl.bind_buffer(uint<-gl.ARRAY_BUFFER, color_buffer)
    gl.enable_vertex_attrib_array(uint<-vcol_location)
    gl.vertex_attrib_pointer(uint<-vcol_location, 3, uint<-gl.FLOAT, ubyte<-gl.FALSE, 0, zero[const_ptr[void]])

    while pump_events():
        var width = window_width
        var height = window_height
        if not sdl.get_window_size_in_pixels(window, out width, out height):
            return 1
        if height == 0:
            height = 1

        let ratio = float<-width / float<-height
        let model = mat4_rotate_z(float<-sdl.get_ticks() / 1000.0)
        let projection = mat4_ortho(-ratio, ratio, -1.0, 1.0, 1.0, -1.0)
        var mvp = mat4_mul(projection, model)

        gl.viewport(0, 0, width, height)
        gl.clear(uint<-gl.COLOR_BUFFER_BIT)
        gl.use_program(program)
        unsafe:
            gl.uniform_matrix_4fv(mvp_location, 1, ubyte<-gl.FALSE, const_ptr[gl.GLfloat]<-ptr_of(mvp[0]))
        gl.bind_vertex_array(vertex_array)
        gl.draw_arrays(uint<-gl.TRIANGLES, 0, 3)

        sdl.gl_swap_window(window)

    return 0


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    return sdl.run_app(argc, argv, app_main)
