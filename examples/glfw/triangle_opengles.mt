module examples.glfw.triangle_opengles

import std.c.glfw as glfw
import std.c.gl as gl
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
    if key == glfw.GLFW_KEY_ESCAPE and action == glfw.GLFW_PRESS:
        glfw.glfwSetWindowShouldClose(window, glfw.GLFW_TRUE)


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
    let shader = gl.glCreateShader(uint<-shader_type)
    var sources = zero[array[const_ptr[gl.GLchar], 1]]
    var source_ptrs = zero[const_ptr[const_ptr[gl.GLchar]]]
    unsafe:
        sources[0] = const_ptr[gl.GLchar]<-source_text
        source_ptrs = const_ptr[const_ptr[gl.GLchar]]<-ptr_of(sources[0])
    gl.glShaderSource(shader, 1, source_ptrs, zero[const_ptr[gl.GLint]])
    gl.glCompileShader(shader)
    return shader


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    if glfw.glfwInit() == 0:
        return 1
    defer glfw.glfwTerminate()

    glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_OPENGL_ES_API)
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MAJOR, 2)
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MINOR, 0)
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_CREATION_API, glfw.GLFW_EGL_CONTEXT_API)

    var window = glfw.glfwCreateWindow(window_width, window_height, window_title_egl, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        glfw.glfwWindowHint(glfw.GLFW_CONTEXT_CREATION_API, glfw.GLFW_NATIVE_CONTEXT_API)
        window = glfw.glfwCreateWindow(window_width, window_height, window_title_native, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
        if window == zero[ptr[glfw.GLFWwindow]]:
            return 1

    defer glfw.glfwDestroyWindow(window)

    glfw.glfwSetKeyCallback(window, key_callback)
    glfw.glfwMakeContextCurrent(window)
    gl.mt_gl_use_glfw_loader()
    glfw.glfwSwapInterval(1)

    var position_buffer: gl.GLuint = 0
    gl.glGenBuffers(1, ptr_of(position_buffer))
    gl.glBindBuffer(uint<-gl.GL_ARRAY_BUFFER, position_buffer)
    unsafe:
        gl.glBufferData(uint<-gl.GL_ARRAY_BUFFER, ptr_int<-(6 * int<-size_of(float)), const_ptr[void]<-ptr_of(positions[0]), uint<-gl.GL_STATIC_DRAW)

    var color_buffer: gl.GLuint = 0
    gl.glGenBuffers(1, ptr_of(color_buffer))
    gl.glBindBuffer(uint<-gl.GL_ARRAY_BUFFER, color_buffer)
    unsafe:
        gl.glBufferData(uint<-gl.GL_ARRAY_BUFFER, ptr_int<-(9 * int<-size_of(float)), const_ptr[void]<-ptr_of(colors[0]), uint<-gl.GL_STATIC_DRAW)

    let vertex_shader = build_shader(uint<-gl.GL_VERTEX_SHADER, vertex_shader_text)
    let fragment_shader = build_shader(uint<-gl.GL_FRAGMENT_SHADER, fragment_shader_text)

    let program = gl.glCreateProgram()
    gl.glAttachShader(program, vertex_shader)
    gl.glAttachShader(program, fragment_shader)
    gl.glLinkProgram(program)

    var mvp_name = zero[const_ptr[gl.GLchar]]
    var vpos_name = zero[const_ptr[gl.GLchar]]
    var vcol_name = zero[const_ptr[gl.GLchar]]
    unsafe:
        mvp_name = const_ptr[gl.GLchar]<-c"MVP"
        vpos_name = const_ptr[gl.GLchar]<-c"vPos"
        vcol_name = const_ptr[gl.GLchar]<-c"vCol"

    let mvp_location = gl.glGetUniformLocation(program, mvp_name)
    let vpos_location = gl.glGetAttribLocation(program, vpos_name)
    let vcol_location = gl.glGetAttribLocation(program, vcol_name)

    gl.glBindBuffer(uint<-gl.GL_ARRAY_BUFFER, position_buffer)
    gl.glEnableVertexAttribArray(uint<-vpos_location)
    gl.glVertexAttribPointer(uint<-vpos_location, 2, uint<-gl.GL_FLOAT, ubyte<-gl.GL_FALSE, 0, zero[const_ptr[void]])

    gl.glBindBuffer(uint<-gl.GL_ARRAY_BUFFER, color_buffer)
    gl.glEnableVertexAttribArray(uint<-vcol_location)
    gl.glVertexAttribPointer(uint<-vcol_location, 3, uint<-gl.GL_FLOAT, ubyte<-gl.GL_FALSE, 0, zero[const_ptr[void]])

    while glfw.glfwWindowShouldClose(window) == 0:
        var width = 0
        var height = 0
        glfw.glfwGetFramebufferSize(window, ptr_of(width), ptr_of(height))
        let ratio = float<-width / float<-height
        let model = mat4_rotate_z(float<-glfw.glfwGetTime())
        let projection = mat4_ortho(-ratio, ratio, -1.0, 1.0, 1.0, -1.0)
        var mvp = mat4_mul(projection, model)

        gl.glViewport(0, 0, width, height)
        gl.glClear(uint<-gl.GL_COLOR_BUFFER_BIT)
        gl.glUseProgram(program)
        unsafe:
            gl.glUniformMatrix4fv(mvp_location, 1, ubyte<-gl.GL_FALSE, const_ptr[gl.GLfloat]<-ptr_of(mvp[0]))
        gl.glDrawArrays(uint<-gl.GL_TRIANGLES, 0, 3)

        glfw.glfwSwapBuffers(window)
        glfw.glfwPollEvents()

    return 0
