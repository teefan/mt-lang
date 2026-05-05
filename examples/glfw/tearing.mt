module examples.glfw.tearing

import std.c.glfw as glfw
import std.c.gl as gl
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
    let shader = gl.glCreateShader(uint<-shader_type)
    var sources = zero[array[const_ptr[gl.GLchar], 1]]
    var source_ptrs = zero[const_ptr[const_ptr[gl.GLchar]]]
    unsafe:
        sources[0] = const_ptr[gl.GLchar]<-source_text
        source_ptrs = const_ptr[const_ptr[gl.GLchar]]<-ptr_of(sources[0])
    gl.glShaderSource(shader, 1, source_ptrs, zero[const_ptr[gl.GLint]])
    gl.glCompileShader(shader)
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
    glfw.glfwSetWindowTitle(window, scratch.to_cstr(title.as_str()))


def set_swap_interval(window: ptr[glfw.GLFWwindow], interval: int) -> void:
    swap_interval = interval
    glfw.glfwSwapInterval(swap_interval)
    update_window_title(window)


def key_callback(window: ptr[glfw.GLFWwindow], key: int, scancode: int, action: int, mods: int) -> void:
    if action != glfw.GLFW_PRESS:
        return

    if key == glfw.GLFW_KEY_UP:
        if swap_interval < 2147483647:
            set_swap_interval(window, swap_interval + 1)
        return

    if key == glfw.GLFW_KEY_DOWN:
        if swap_tear:
            if swap_interval > -2147483647:
                set_swap_interval(window, swap_interval - 1)
        else:
            if swap_interval > 0:
                set_swap_interval(window, swap_interval - 1)
        return

    if key == glfw.GLFW_KEY_ESCAPE:
        glfw.glfwSetWindowShouldClose(window, glfw.GLFW_TRUE)
        return

    if ((key == glfw.GLFW_KEY_ENTER and mods == glfw.GLFW_MOD_ALT) or (key == glfw.GLFW_KEY_F11 and mods == glfw.GLFW_MOD_ALT)):
        if glfw.glfwGetWindowMonitor(window) != zero[ptr[glfw.GLFWmonitor]]:
            glfw.glfwSetWindowMonitor(window, zero[ptr[glfw.GLFWmonitor]], windowed_xpos, windowed_ypos, windowed_width, windowed_height, 0)
            return

        let monitor = glfw.glfwGetPrimaryMonitor()
        if monitor != zero[ptr[glfw.GLFWmonitor]]:
            let mode_ptr = glfw.glfwGetVideoMode(monitor)
            if mode_ptr != zero[const_ptr[glfw.GLFWvidmode]]:
                var mode = zero[glfw.GLFWvidmode]
                unsafe:
                    mode = read(mode_ptr)
                glfw.glfwGetWindowPos(window, ptr_of(windowed_xpos), ptr_of(windowed_ypos))
                glfw.glfwGetWindowSize(window, ptr_of(windowed_width), ptr_of(windowed_height))
                glfw.glfwSetWindowMonitor(window, monitor, 0, 0, mode.width, mode.height, mode.refreshRate)


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    glfw.glfwSetErrorCallback(error_callback)

    if glfw.glfwInit() == 0:
        return 1
    defer glfw.glfwTerminate()

    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MAJOR, 2)
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MINOR, 0)

    let window = glfw.glfwCreateWindow(window_width, window_height, window_title, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.glfwDestroyWindow(window)

    glfw.glfwMakeContextCurrent(window)
    gl.mt_gl_use_glfw_loader()
    set_swap_interval(window, 0)

    swap_tear = glfw.glfwExtensionSupported(extension_wgl_swap_tear) != 0 or glfw.glfwExtensionSupported(extension_glx_swap_tear) != 0
    glfw.glfwSetKeyCallback(window, key_callback)

    var vertex_buffer: gl.GLuint = 0
    gl.glGenBuffers(1, ptr_of(vertex_buffer))
    gl.glBindBuffer(uint<-gl.GL_ARRAY_BUFFER, vertex_buffer)
    unsafe:
        gl.glBufferData(uint<-gl.GL_ARRAY_BUFFER, ptr_int<-(8 * int<-size_of(float)), const_ptr[void]<-ptr_of(vertices[0]), uint<-gl.GL_STATIC_DRAW)

    let vertex_shader = build_shader(uint<-gl.GL_VERTEX_SHADER, vertex_shader_text)
    let fragment_shader = build_shader(uint<-gl.GL_FRAGMENT_SHADER, fragment_shader_text)

    let program = gl.glCreateProgram()
    gl.glAttachShader(program, vertex_shader)
    gl.glAttachShader(program, fragment_shader)
    gl.glLinkProgram(program)

    var mvp_name = zero[const_ptr[gl.GLchar]]
    var vpos_name = zero[const_ptr[gl.GLchar]]
    unsafe:
        mvp_name = const_ptr[gl.GLchar]<-c"MVP"
        vpos_name = const_ptr[gl.GLchar]<-c"vPos"

    let mvp_location = gl.glGetUniformLocation(program, mvp_name)
    let vpos_location = gl.glGetAttribLocation(program, vpos_name)
    gl.glEnableVertexAttribArray(uint<-vpos_location)
    gl.glVertexAttribPointer(uint<-vpos_location, 2, uint<-gl.GL_FLOAT, ubyte<-gl.GL_FALSE, 2 * int<-size_of(float), zero[const_ptr[void]])

    var frame_count: double = 0.0
    var last_time = glfw.glfwGetTime()
    while glfw.glfwWindowShouldClose(window) == 0:
        var width = 0
        var height = 0
        let position = math.cosf(float<-glfw.glfwGetTime() * 4.0) * 0.75

        glfw.glfwGetFramebufferSize(window, ptr_of(width), ptr_of(height))
        gl.glViewport(0, 0, width, height)
        gl.glClear(uint<-gl.GL_COLOR_BUFFER_BIT)

        let projection = mat4_ortho(-1.0, 1.0, -1.0, 1.0, 0.0, 1.0)
        let model = mat4_translate(position, 0.0, 0.0)
        var mvp = mat4_mul(projection, model)

        gl.glUseProgram(program)
        unsafe:
            gl.glUniformMatrix4fv(mvp_location, 1, ubyte<-gl.GL_FALSE, const_ptr[gl.GLfloat]<-ptr_of(mvp[0]))
        gl.glDrawArrays(uint<-gl.GL_TRIANGLE_FAN, 0, 4)

        glfw.glfwSwapBuffers(window)
        glfw.glfwPollEvents()

        frame_count += 1.0
        let current_time = glfw.glfwGetTime()
        if current_time - last_time > 1.0:
            frame_rate = frame_count / (current_time - last_time)
            frame_count = 0.0
            last_time = current_time
            update_window_title(window)

    return 0
