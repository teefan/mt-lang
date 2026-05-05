module examples.glfw.sharing

import std.c.glfw as glfw
import std.c.gl as gl

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
    if action == glfw.GLFW_PRESS and key == glfw.GLFW_KEY_ESCAPE:
        glfw.glfwSetWindowShouldClose(window, glfw.GLFW_TRUE)


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
    let shader = gl.glCreateShader(uint<-shader_type)
    var sources = zero[array[const_ptr[gl.GLchar], 1]]
    var source_ptrs = zero[const_ptr[const_ptr[gl.GLchar]]]
    unsafe:
        sources[0] = const_ptr[gl.GLchar]<-source_text
        source_ptrs = const_ptr[const_ptr[gl.GLchar]]<-ptr_of(sources[0])
    gl.glShaderSource(shader, 1, source_ptrs, zero[const_ptr[gl.GLint]])
    gl.glCompileShader(shader)
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
    gl.glUseProgram(program)
    gl.glUniform1i(texture_location, 0)
    gl.glEnable(uint<-gl.GL_TEXTURE_2D)
    gl.glBindTexture(uint<-gl.GL_TEXTURE_2D, texture)
    gl.glBindBuffer(uint<-gl.GL_ARRAY_BUFFER, vertex_buffer)
    gl.glEnableVertexAttribArray(uint<-vpos_location)
    gl.glVertexAttribPointer(uint<-vpos_location, 2, uint<-gl.GL_FLOAT, ubyte<-gl.GL_FALSE, 0, zero[const_ptr[void]])


def should_close(window: ptr[glfw.GLFWwindow]) -> bool:
    return glfw.glfwWindowShouldClose(window) != 0


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    glfw.glfwSetErrorCallback(error_callback)

    if glfw.glfwInit() == 0:
        return 1
    defer glfw.glfwTerminate()

    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MAJOR, 2)
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MINOR, 0)

    let first_window = glfw.glfwCreateWindow(400, 400, first_window_title, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if first_window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.glfwDestroyWindow(first_window)
    windows[0] = first_window
    glfw.glfwSetKeyCallback(first_window, key_callback)

    glfw.glfwMakeContextCurrent(first_window)
    gl.mt_gl_use_glfw_loader()
    glfw.glfwSwapInterval(1)
    fill_texture_pixels()

    var texture: gl.GLuint = 0
    gl.glGenTextures(1, ptr_of(texture))
    gl.glBindTexture(uint<-gl.GL_TEXTURE_2D, texture)
    unsafe:
        gl.glTexImage2D(uint<-gl.GL_TEXTURE_2D, 0, int<-gl.GL_LUMINANCE, texture_size, texture_size, 0, uint<-gl.GL_LUMINANCE, uint<-gl.GL_UNSIGNED_BYTE, const_ptr[void]<-ptr_of(texture_pixels[0]))
    gl.glTexParameteri(uint<-gl.GL_TEXTURE_2D, uint<-gl.GL_TEXTURE_MIN_FILTER, int<-gl.GL_NEAREST)
    gl.glTexParameteri(uint<-gl.GL_TEXTURE_2D, uint<-gl.GL_TEXTURE_MAG_FILTER, int<-gl.GL_NEAREST)

    let vertex_shader = build_shader(uint<-gl.GL_VERTEX_SHADER, vertex_shader_text)
    let fragment_shader = build_shader(uint<-gl.GL_FRAGMENT_SHADER, fragment_shader_text)

    let program = gl.glCreateProgram()
    gl.glAttachShader(program, vertex_shader)
    gl.glAttachShader(program, fragment_shader)
    gl.glLinkProgram(program)

    var mvp_name = zero[const_ptr[gl.GLchar]]
    var color_name = zero[const_ptr[gl.GLchar]]
    var texture_name = zero[const_ptr[gl.GLchar]]
    var vpos_name = zero[const_ptr[gl.GLchar]]
    unsafe:
        mvp_name = const_ptr[gl.GLchar]<-c"MVP"
        color_name = const_ptr[gl.GLchar]<-c"color"
        texture_name = const_ptr[gl.GLchar]<-c"texture"
        vpos_name = const_ptr[gl.GLchar]<-c"vPos"

    let mvp_location = gl.glGetUniformLocation(program, mvp_name)
    let color_location = gl.glGetUniformLocation(program, color_name)
    let texture_location = gl.glGetUniformLocation(program, texture_name)
    let vpos_location = gl.glGetAttribLocation(program, vpos_name)

    var vertex_buffer: gl.GLuint = 0
    gl.glGenBuffers(1, ptr_of(vertex_buffer))
    gl.glBindBuffer(uint<-gl.GL_ARRAY_BUFFER, vertex_buffer)
    unsafe:
        gl.glBufferData(uint<-gl.GL_ARRAY_BUFFER, ptr_int<-(8 * int<-size_of(float)), const_ptr[void]<-ptr_of(quad_vertices[0]), uint<-gl.GL_STATIC_DRAW)
    configure_context(program, texture, vertex_buffer, vpos_location, texture_location)

    let second_window = glfw.glfwCreateWindow(400, 400, second_window_title, zero[ptr[glfw.GLFWmonitor]], first_window)
    if second_window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.glfwDestroyWindow(second_window)
    windows[1] = second_window

    var xpos = 0
    var ypos = 0
    var width = 0
    var left = 0
    var right = 0
    glfw.glfwGetWindowSize(first_window, ptr_of(width), zero[ptr[int]])
    glfw.glfwGetWindowFrameSize(first_window, ptr_of(left), zero[ptr[int]], ptr_of(right), zero[ptr[int]])
    glfw.glfwGetWindowPos(first_window, ptr_of(xpos), ptr_of(ypos))
    glfw.glfwSetWindowPos(second_window, xpos + width + left + right, ypos)
    glfw.glfwSetKeyCallback(second_window, key_callback)

    glfw.glfwMakeContextCurrent(second_window)
    gl.mt_gl_use_glfw_loader()
    configure_context(program, texture, vertex_buffer, vpos_location, texture_location)

    while not should_close(first_window) and not should_close(second_window):
        var index = 0
        while index < 2:
            let window = windows[index]
            glfw.glfwMakeContextCurrent(window)
            gl.mt_gl_use_glfw_loader()
            configure_context(program, texture, vertex_buffer, vpos_location, texture_location)

            var framebuffer_width = 0
            var framebuffer_height = 0
            glfw.glfwGetFramebufferSize(window, ptr_of(framebuffer_width), ptr_of(framebuffer_height))
            var mvp = mat4_ortho(0.0, 1.0, 0.0, 1.0, 0.0, 1.0)

            gl.glViewport(0, 0, framebuffer_width, framebuffer_height)
            gl.glClear(uint<-gl.GL_COLOR_BUFFER_BIT)
            unsafe:
                gl.glUniformMatrix4fv(mvp_location, 1, ubyte<-gl.GL_FALSE, const_ptr[gl.GLfloat]<-ptr_of(mvp[0]))
            gl.glUniform3f(color_location, tint_colors[index * 3], tint_colors[index * 3 + 1], tint_colors[index * 3 + 2])
            gl.glDrawArrays(uint<-gl.GL_TRIANGLE_FAN, 0, 4)

            glfw.glfwSwapBuffers(window)
            index += 1

        glfw.glfwWaitEvents()

    return 0
