module examples.idiomatic.glfw.offscreen

import std.glfw as glfw
import std.gl as gl
import std.gl.util as gl_util

type Mat4 = array[float, 16]

const window_width: int = 640
const window_height: int = 480
const window_title: cstr = c"Offscreen Example"
const pixel_count: int = window_width * window_height * 4
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
    #version 110
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
    #version 110
    varying vec3 color;
    void main()
    {
        gl_FragColor = vec4(color, 1.0);
    }
GLSL

var pixels: array[ubyte, pixel_count] = zero[array[ubyte, pixel_count]]


def mat4_ortho(left: float, right: float, bottom: float, top: float, near: float, far: float) -> Mat4:
    return array[float, 16](
        2.0 / (right - left), 0.0, 0.0, 0.0,
        0.0, 2.0 / (top - bottom), 0.0, 0.0,
        0.0, 0.0, -2.0 / (far - near), 0.0,
        -((right + left) / (right - left)), -((top + bottom) / (top - bottom)), -((far + near) / (far - near)), 1.0,
    )


def main() -> int:
    glfw.init_hint(glfw.COCOA_MENUBAR, glfw.FALSE)

    if glfw.init() == 0:
        return 1
    defer glfw.terminate()

    glfw.window_hint(glfw.CONTEXT_VERSION_MAJOR, 2)
    glfw.window_hint(glfw.CONTEXT_VERSION_MINOR, 0)
    glfw.window_hint(glfw.VISIBLE, glfw.FALSE)

    let window = glfw.create_window(window_width, window_height, window_title, null, null)
    if window == null:
        return 1
    defer glfw.destroy_window(window)

    glfw.make_context_current(window)
    gl.use_glfw_loader()

    var position_buffer: gl.GLuint = 0
    gl.gen_buffers(1, ptr_of(position_buffer))
    gl.bind_buffer(uint<-gl.ARRAY_BUFFER, position_buffer)
    gl_util.buffer_data(uint<-gl.ARRAY_BUFFER, positions, uint<-gl.STATIC_DRAW)

    var color_buffer: gl.GLuint = 0
    gl.gen_buffers(1, ptr_of(color_buffer))
    gl.bind_buffer(uint<-gl.ARRAY_BUFFER, color_buffer)
    gl_util.buffer_data(uint<-gl.ARRAY_BUFFER, colors, uint<-gl.STATIC_DRAW)

    let vertex_shader = gl_util.build_shader(uint<-gl.VERTEX_SHADER, vertex_shader_text)
    let fragment_shader = gl_util.build_shader(uint<-gl.FRAGMENT_SHADER, fragment_shader_text)

    let program = gl.create_program()
    gl.attach_shader(program, vertex_shader)
    gl.attach_shader(program, fragment_shader)
    gl.link_program(program)

    let mvp_location = gl_util.uniform_location(program, c"MVP")
    let vpos_location = gl_util.attrib_location(program, c"vPos")
    let vcol_location = gl_util.attrib_location(program, c"vCol")

    gl.bind_buffer(uint<-gl.ARRAY_BUFFER, position_buffer)
    gl.enable_vertex_attrib_array(uint<-vpos_location)
    gl.vertex_attrib_pointer(uint<-vpos_location, 2, uint<-gl.FLOAT, ubyte<-gl.FALSE, 0, zero[const_ptr[void]])

    gl.bind_buffer(uint<-gl.ARRAY_BUFFER, color_buffer)
    gl.enable_vertex_attrib_array(uint<-vcol_location)
    gl.vertex_attrib_pointer(uint<-vcol_location, 3, uint<-gl.FLOAT, ubyte<-gl.FALSE, 0, zero[const_ptr[void]])

    var width = 0
    var height = 0
    glfw.get_framebuffer_size(window, ptr_of(width), ptr_of(height))

    let ratio = float<-width / float<-height
    var mvp = mat4_ortho(-ratio, ratio, -1.0, 1.0, 1.0, -1.0)

    gl.viewport(0, 0, width, height)
    gl.clear(uint<-gl.COLOR_BUFFER_BIT)
    gl.use_program(program)
    gl_util.uniform_matrix_4(mvp_location, ubyte<-gl.FALSE, mvp)
    gl.draw_arrays(uint<-gl.TRIANGLES, 0, 3)
    gl.finish()
    unsafe:
        gl.read_pixels(0, 0, width, height, uint<-gl.RGBA, uint<-gl.UNSIGNED_BYTE, ptr[void]<-ptr_of(pixels[0]))

    return 0
