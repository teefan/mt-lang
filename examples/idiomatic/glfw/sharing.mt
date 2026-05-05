module examples.idiomatic.glfw.sharing

import std.glfw as glfw
import std.gl as gl

type Mat4 = array[float, 16]

const texture_size: int = 16
const texture_pixels_len: int = texture_size * texture_size
const first_window_title: cstr = c"First"
const second_window_title: cstr = c"Second"
const vertex_shader_text: cstr = c<<-GLSL
    #version 110
    uniform mat4 MVP;
    attribute vec2 vPos;
    varying vec2 texcoord;
    void main()
    {
        gl_Position = MVP * vec4(vPos, 0.0, 1.0);
        texcoord = vPos;
    }
GLSL
const fragment_shader_text: cstr = c<<-GLSL
    #version 110
    uniform sampler2D texture;
    uniform vec3 color;
    varying vec2 texcoord;
    void main()
    {
        gl_FragColor = vec4(color * texture2D(texture, texcoord).rgb, 1.0);
    }
GLSL

var quad_vertices: array[float, 8] = array[float, 8](
    0.0, 0.0,
    1.0, 0.0,
    1.0, 1.0,
    0.0, 1.0,
)
var texture_pixels: array[ubyte, texture_pixels_len] = zero[array[ubyte, texture_pixels_len]]
var tint_colors: array[float, 6] = array[float, 6](
    0.8, 0.4, 1.0,
    0.3, 0.4, 1.0,
)
var windows: array[ptr[glfw.GLFWwindow], 2] = zero[array[ptr[glfw.GLFWwindow], 2]]


def key_callback(window: ptr[glfw.GLFWwindow], key: int, scancode: int, action: int, mods: int) -> void:
    if action == glfw.PRESS and key == glfw.KEY_ESCAPE:
        glfw.set_window_should_close(window, glfw.TRUE)


def error_callback(error: int, description: cstr) -> void:
    return


def mat4_ortho(left: float, right: float, bottom: float, top: float, near: float, far: float) -> Mat4:
    return array[float, 16](
        2.0 / (right - left), 0.0, 0.0, 0.0,
        0.0, 2.0 / (top - bottom), 0.0, 0.0,
        0.0, 0.0, -2.0 / (far - near), 0.0,
        -((right + left) / (right - left)), -((top + bottom) / (top - bottom)), -((far + near) / (far - near)), 1.0,
    )


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


def fill_texture_pixels() -> void:
    var y = 0
    while y < texture_size:
        var x = 0
        while x < texture_size:
            let block = ((x / 4) + (y / 4)) & 1
            texture_pixels[y * texture_size + x] = if block == 0: 48 else: 232
            x += 1
        y += 1


def configure_context(program: gl.GLuint, texture: gl.GLuint, vertex_buffer: gl.GLuint, vpos_location: int, texture_location: int) -> void:
    gl.use_program(program)
    gl.uniform_1i(texture_location, 0)
    gl.enable(uint<-gl.TEXTURE_2D)
    gl.bind_texture(uint<-gl.TEXTURE_2D, texture)
    gl.bind_buffer(uint<-gl.ARRAY_BUFFER, vertex_buffer)
    gl.enable_vertex_attrib_array(uint<-vpos_location)
    gl.vertex_attrib_pointer(uint<-vpos_location, 2, uint<-gl.FLOAT, ubyte<-gl.FALSE, 0, zero[const_ptr[void]])


def should_close(window: ptr[glfw.GLFWwindow]) -> bool:
    return glfw.window_should_close(window) != 0


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    glfw.set_error_callback(error_callback)

    if glfw.init() == 0:
        return 1
    defer glfw.terminate()

    glfw.window_hint(glfw.CONTEXT_VERSION_MAJOR, 2)
    glfw.window_hint(glfw.CONTEXT_VERSION_MINOR, 0)

    let first_window = glfw.create_window(400, 400, first_window_title, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if first_window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.destroy_window(first_window)
    windows[0] = first_window
    glfw.set_key_callback(first_window, key_callback)

    glfw.make_context_current(first_window)
    gl.use_glfw_loader()
    glfw.swap_interval(1)
    fill_texture_pixels()

    var texture: gl.GLuint = 0
    gl.gen_textures(1, ptr_of(texture))
    gl.bind_texture(uint<-gl.TEXTURE_2D, texture)
    unsafe:
        gl.tex_image_2d(uint<-gl.TEXTURE_2D, 0, int<-gl.LUMINANCE, texture_size, texture_size, 0, uint<-gl.LUMINANCE, uint<-gl.UNSIGNED_BYTE, const_ptr[void]<-ptr_of(texture_pixels[0]))
    gl.tex_parameteri(uint<-gl.TEXTURE_2D, uint<-gl.TEXTURE_MIN_FILTER, int<-gl.NEAREST)
    gl.tex_parameteri(uint<-gl.TEXTURE_2D, uint<-gl.TEXTURE_MAG_FILTER, int<-gl.NEAREST)

    let vertex_shader = build_shader(uint<-gl.VERTEX_SHADER, vertex_shader_text)
    let fragment_shader = build_shader(uint<-gl.FRAGMENT_SHADER, fragment_shader_text)

    let program = gl.create_program()
    gl.attach_shader(program, vertex_shader)
    gl.attach_shader(program, fragment_shader)
    gl.link_program(program)

    var mvp_name = zero[const_ptr[gl.GLchar]]
    var color_name = zero[const_ptr[gl.GLchar]]
    var texture_name = zero[const_ptr[gl.GLchar]]
    var vpos_name = zero[const_ptr[gl.GLchar]]
    unsafe:
        mvp_name = const_ptr[gl.GLchar]<-c"MVP"
        color_name = const_ptr[gl.GLchar]<-c"color"
        texture_name = const_ptr[gl.GLchar]<-c"texture"
        vpos_name = const_ptr[gl.GLchar]<-c"vPos"

    let mvp_location = gl.get_uniform_location(program, mvp_name)
    let color_location = gl.get_uniform_location(program, color_name)
    let texture_location = gl.get_uniform_location(program, texture_name)
    let vpos_location = gl.get_attrib_location(program, vpos_name)

    var vertex_buffer: gl.GLuint = 0
    gl.gen_buffers(1, ptr_of(vertex_buffer))
    gl.bind_buffer(uint<-gl.ARRAY_BUFFER, vertex_buffer)
    unsafe:
        gl.buffer_data(uint<-gl.ARRAY_BUFFER, ptr_int<-(8 * int<-size_of(float)), const_ptr[void]<-ptr_of(quad_vertices[0]), uint<-gl.STATIC_DRAW)
    configure_context(program, texture, vertex_buffer, vpos_location, texture_location)

    let second_window = glfw.create_window(400, 400, second_window_title, zero[ptr[glfw.GLFWmonitor]], first_window)
    if second_window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.destroy_window(second_window)
    windows[1] = second_window

    var xpos = 0
    var ypos = 0
    var width = 0
    var left = 0
    var right = 0
    glfw.get_window_size(first_window, ptr_of(width), zero[ptr[int]])
    glfw.get_window_frame_size(first_window, ptr_of(left), zero[ptr[int]], ptr_of(right), zero[ptr[int]])
    glfw.get_window_pos(first_window, ptr_of(xpos), ptr_of(ypos))
    glfw.set_window_pos(second_window, xpos + width + left + right, ypos)
    glfw.set_key_callback(second_window, key_callback)

    glfw.make_context_current(second_window)
    gl.use_glfw_loader()
    configure_context(program, texture, vertex_buffer, vpos_location, texture_location)

    while not should_close(first_window) and not should_close(second_window):
        var index = 0
        while index < 2:
            let window = windows[index]
            glfw.make_context_current(window)
            gl.use_glfw_loader()
            configure_context(program, texture, vertex_buffer, vpos_location, texture_location)

            var framebuffer_width = 0
            var framebuffer_height = 0
            glfw.get_framebuffer_size(window, ptr_of(framebuffer_width), ptr_of(framebuffer_height))
            var mvp = mat4_ortho(0.0, 1.0, 0.0, 1.0, 0.0, 1.0)

            gl.viewport(0, 0, framebuffer_width, framebuffer_height)
            gl.clear(uint<-gl.COLOR_BUFFER_BIT)
            unsafe:
                gl.uniform_matrix_4fv(mvp_location, 1, ubyte<-gl.FALSE, const_ptr[gl.GLfloat]<-ptr_of(mvp[0]))
            gl.uniform_3f(color_location, tint_colors[index * 3], tint_colors[index * 3 + 1], tint_colors[index * 3 + 2])
            gl.draw_arrays(uint<-gl.TRIANGLE_FAN, 0, 4)

            glfw.swap_buffers(window)
            index += 1

        glfw.wait_events()

    return 0
