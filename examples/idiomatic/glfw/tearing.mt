module examples.idiomatic.glfw.tearing

import std.glfw as glfw
import std.gl as gl
import std.c.libm as math
import std.fmt as fmt
import std.mem.arena as arena
import std.string as string

type Mat4 = array[float, 16]

const window_width: int = 640
const window_height: int = 480
const window_title: cstr = c"Tearing detector"
const extension_wgl_swap_tear: cstr = c"WGL_EXT_swap_control_tear"
const extension_glx_swap_tear: cstr = c"GLX_EXT_swap_control_tear"

var vertices: array[float, 8] = array[float, 8](
    -0.25, -1.0,
    0.25, -1.0,
    0.25, 1.0,
    -0.25, 1.0,
)

const vertex_shader_text: cstr = c<<-GLSL
    #version 110
    uniform mat4 MVP;
    attribute vec2 vPos;
    void main()
    {
        gl_Position = MVP * vec4(vPos, 0.0, 1.0);
    }
GLSL
const fragment_shader_text: cstr = c<<-GLSL
    #version 110
    void main()
    {
        gl_FragColor = vec4(1.0);
    }
GLSL

var swap_tear: bool = false
var swap_interval: int = 0
var frame_rate: double = 0.0
var windowed_xpos: int = 0
var windowed_ypos: int = 0
var windowed_width: int = window_width
var windowed_height: int = window_height


def error_callback(error: int, description: cstr) -> void:
    return


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


def mat4_translate(x: float, y: float, z: float) -> Mat4:
    return array[float, 16](
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        x, y, z, 1.0,
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


def update_window_title(window: ptr[glfw.GLFWwindow]) -> void:
    var title: string.String = fmt.string("Tearing detector (interval ")
    defer title.release()
    fmt.append_int(ref_of(title), swap_interval)
    if swap_tear and swap_interval < 0:
        fmt.append_str(ref_of(title), " (swap tear)")
    fmt.append_str(ref_of(title), ", ")
    fmt.append_double_precision(ref_of(title), frame_rate, 1)
    fmt.append_str(ref_of(title), " Hz)")

    var scratch = arena.create(128)
    defer scratch.release()
    glfw.set_window_title(window, scratch.to_cstr(title.as_str()))


def set_swap_interval(window: ptr[glfw.GLFWwindow], interval: int) -> void:
    swap_interval = interval
    glfw.swap_interval(swap_interval)
    update_window_title(window)


def key_callback(window: ptr[glfw.GLFWwindow], key: int, scancode: int, action: int, mods: int) -> void:
    if action != glfw.PRESS:
        return

    if key == glfw.KEY_UP:
        if swap_interval < 2147483647:
            set_swap_interval(window, swap_interval + 1)
        return

    if key == glfw.KEY_DOWN:
        if swap_tear:
            if swap_interval > -2147483647:
                set_swap_interval(window, swap_interval - 1)
        else:
            if swap_interval > 0:
                set_swap_interval(window, swap_interval - 1)
        return

    if key == glfw.KEY_ESCAPE:
        glfw.set_window_should_close(window, glfw.TRUE)
        return

    if ((key == glfw.KEY_ENTER and mods == glfw.MOD_ALT) or (key == glfw.KEY_F11 and mods == glfw.MOD_ALT)):
        if glfw.get_window_monitor(window) != zero[ptr[glfw.GLFWmonitor]]:
            glfw.set_window_monitor(window, zero[ptr[glfw.GLFWmonitor]], windowed_xpos, windowed_ypos, windowed_width, windowed_height, 0)
            return

        let monitor = glfw.get_primary_monitor()
        if monitor != zero[ptr[glfw.GLFWmonitor]]:
            let mode_ptr = glfw.get_video_mode(monitor)
            if mode_ptr != zero[const_ptr[glfw.GLFWvidmode]]:
                var mode = zero[glfw.GLFWvidmode]
                unsafe:
                    mode = read(mode_ptr)
                glfw.get_window_pos(window, ptr_of(windowed_xpos), ptr_of(windowed_ypos))
                glfw.get_window_size(window, ptr_of(windowed_width), ptr_of(windowed_height))
                glfw.set_window_monitor(window, monitor, 0, 0, mode.width, mode.height, mode.refreshRate)


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    glfw.set_error_callback(error_callback)

    if glfw.init() == 0:
        return 1
    defer glfw.terminate()

    glfw.window_hint(glfw.CONTEXT_VERSION_MAJOR, 2)
    glfw.window_hint(glfw.CONTEXT_VERSION_MINOR, 0)

    let window = glfw.create_window(window_width, window_height, window_title, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.destroy_window(window)

    glfw.make_context_current(window)
    gl.use_glfw_loader()
    set_swap_interval(window, 0)

    swap_tear = glfw.extension_supported(extension_wgl_swap_tear) != 0 or glfw.extension_supported(extension_glx_swap_tear) != 0
    glfw.set_key_callback(window, key_callback)

    var vertex_buffer: gl.GLuint = 0
    gl.gen_buffers(1, ptr_of(vertex_buffer))
    gl.bind_buffer(uint<-gl.ARRAY_BUFFER, vertex_buffer)
    unsafe:
        gl.buffer_data(uint<-gl.ARRAY_BUFFER, ptr_int<-(8 * int<-size_of(float)), const_ptr[void]<-ptr_of(vertices[0]), uint<-gl.STATIC_DRAW)

    let vertex_shader = build_shader(uint<-gl.VERTEX_SHADER, vertex_shader_text)
    let fragment_shader = build_shader(uint<-gl.FRAGMENT_SHADER, fragment_shader_text)

    let program = gl.create_program()
    gl.attach_shader(program, vertex_shader)
    gl.attach_shader(program, fragment_shader)
    gl.link_program(program)

    var mvp_name = zero[const_ptr[gl.GLchar]]
    var vpos_name = zero[const_ptr[gl.GLchar]]
    unsafe:
        mvp_name = const_ptr[gl.GLchar]<-c"MVP"
        vpos_name = const_ptr[gl.GLchar]<-c"vPos"

    let mvp_location = gl.get_uniform_location(program, mvp_name)
    let vpos_location = gl.get_attrib_location(program, vpos_name)
    gl.enable_vertex_attrib_array(uint<-vpos_location)
    gl.vertex_attrib_pointer(uint<-vpos_location, 2, uint<-gl.FLOAT, ubyte<-gl.FALSE, 2 * int<-size_of(float), zero[const_ptr[void]])

    var frame_count: double = 0.0
    var last_time = glfw.get_time()
    while glfw.window_should_close(window) == 0:
        var width = 0
        var height = 0
        let position = math.cosf(float<-glfw.get_time() * 4.0) * 0.75

        glfw.get_framebuffer_size(window, ptr_of(width), ptr_of(height))
        gl.viewport(0, 0, width, height)
        gl.clear(uint<-gl.COLOR_BUFFER_BIT)

        let projection = mat4_ortho(-1.0, 1.0, -1.0, 1.0, 0.0, 1.0)
        let model = mat4_translate(position, 0.0, 0.0)
        var mvp = mat4_mul(projection, model)

        gl.use_program(program)
        unsafe:
            gl.uniform_matrix_4fv(mvp_location, 1, ubyte<-gl.FALSE, const_ptr[gl.GLfloat]<-ptr_of(mvp[0]))
        gl.draw_arrays(uint<-gl.TRIANGLE_FAN, 0, 4)

        glfw.swap_buffers(window)
        glfw.poll_events()

        frame_count += 1.0
        let current_time = glfw.get_time()
        if current_time - last_time > 1.0:
            frame_rate = frame_count / (current_time - last_time)
            frame_count = 0.0
            last_time = current_time
            update_window_title(window)

    return 0
