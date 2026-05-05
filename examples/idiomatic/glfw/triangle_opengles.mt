module examples.idiomatic.glfw.triangle_opengles

import std.glfw as glfw
import std.gl as gl
import std.c.libm as math

type Mat4 = array[float, 16]

const window_width: int = 640
const window_height: int = 480
const window_title_egl: cstr = c"OpenGL ES 2.0 Triangle (EGL)"
const window_title_native: cstr = c"OpenGL ES 2.0 Triangle"
const deg_to_rad: float = 0.017453292519943295
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
    #version 100
    precision mediump float;
    uniform mat4 MVP;
    attribute vec3 vCol;
    attribute vec2 vPos;
    varying vec3 color;
    void main()
    {
        gl_Position = MVP * vec4(vPos, 0.0, 1.0);
        color = vCol;
    }
GLSL
const fragment_shader_text: cstr = c<<-GLSL
    #version 100
    precision mediump float;
    varying vec3 color;
    void main()
    {
        gl_FragColor = vec4(color, 1.0);
    }
GLSL


def key_callback(window: ptr[glfw.GLFWwindow], key: int, scancode: int, action: int, mods: int) -> void:
    if key == glfw.KEY_ESCAPE and action == glfw.PRESS:
        glfw.set_window_should_close(window, glfw.TRUE)


def mat4_identity() -> Mat4:
    return array[float, 16](
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    )


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


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    if glfw.init() == 0:
        return 1
    defer glfw.terminate()

    glfw.window_hint(glfw.CLIENT_API, glfw.OPENGL_ES_API)
    glfw.window_hint(glfw.CONTEXT_VERSION_MAJOR, 2)
    glfw.window_hint(glfw.CONTEXT_VERSION_MINOR, 0)
    glfw.window_hint(glfw.CONTEXT_CREATION_API, glfw.EGL_CONTEXT_API)

    var window = glfw.create_window(window_width, window_height, window_title_egl, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        glfw.window_hint(glfw.CONTEXT_CREATION_API, glfw.NATIVE_CONTEXT_API)
        window = glfw.create_window(window_width, window_height, window_title_native, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
        if window == zero[ptr[glfw.GLFWwindow]]:
            return 1

    defer glfw.destroy_window(window)

    glfw.set_key_callback(window, key_callback)
    glfw.make_context_current(window)
    gl.use_glfw_loader()
    glfw.swap_interval(1)

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

    gl.bind_buffer(uint<-gl.ARRAY_BUFFER, position_buffer)
    gl.enable_vertex_attrib_array(uint<-vpos_location)
    gl.vertex_attrib_pointer(uint<-vpos_location, 2, uint<-gl.FLOAT, ubyte<-gl.FALSE, 0, zero[const_ptr[void]])

    gl.bind_buffer(uint<-gl.ARRAY_BUFFER, color_buffer)
    gl.enable_vertex_attrib_array(uint<-vcol_location)
    gl.vertex_attrib_pointer(uint<-vcol_location, 3, uint<-gl.FLOAT, ubyte<-gl.FALSE, 0, zero[const_ptr[void]])

    while glfw.window_should_close(window) == 0:
        var width = 0
        var height = 0
        glfw.get_framebuffer_size(window, ptr_of(width), ptr_of(height))
        let ratio = float<-width / float<-height
        let model = mat4_rotate_z(float<-glfw.get_time())
        let projection = mat4_ortho(-ratio, ratio, -1.0, 1.0, 1.0, -1.0)
        var mvp = mat4_mul(projection, model)

        gl.viewport(0, 0, width, height)
        gl.clear(uint<-gl.COLOR_BUFFER_BIT)
        gl.use_program(program)
        unsafe:
            gl.uniform_matrix_4fv(mvp_location, 1, ubyte<-gl.FALSE, const_ptr[gl.GLfloat]<-ptr_of(mvp[0]))
        gl.draw_arrays(uint<-gl.TRIANGLES, 0, 3)

        glfw.swap_buffers(window)
        glfw.poll_events()

    return 0
