module examples.glfw.title

import std.c.glfw as glfw
import std.c.gl as gl

const window_width: int = 400
const window_height: int = 400
const window_title_utf8: cstr = c"English 日本語 русский язык 官話"


def error_callback(error: int, description: cstr) -> void:
    return


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    glfw.glfwSetErrorCallback(error_callback)

    if glfw.glfwInit() == 0:
        return 1
    defer glfw.glfwTerminate()

    let window = glfw.glfwCreateWindow(window_width, window_height, window_title_utf8, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.glfwDestroyWindow(window)

    glfw.glfwMakeContextCurrent(window)
    gl.mt_gl_use_glfw_loader()
    glfw.glfwSwapInterval(1)

    while glfw.glfwWindowShouldClose(window) == 0:
        gl.glClear(uint<-gl.GL_COLOR_BUFFER_BIT)
        glfw.glfwSwapBuffers(window)
        glfw.glfwWaitEvents()

    return 0
