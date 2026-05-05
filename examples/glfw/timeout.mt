module examples.glfw.timeout

import std.c.glfw as glfw
import std.c.gl as gl
import std.c.libc as libc
import std.c.libm as math

const window_width: int = 640
const window_height: int = 480
const window_title: cstr = c"Event Wait Timeout Test"

var needs_update: bool = false


def window_close_callback(window: ptr[glfw.GLFWwindow]) -> void:
    needs_update = true


def error_callback(error: int, description: cstr) -> void:
    return


def key_callback(window: ptr[glfw.GLFWwindow], key: int, scancode: int, action: int, mods: int) -> void:
    if key == glfw.GLFW_KEY_ESCAPE and action == glfw.GLFW_PRESS:
        glfw.glfwSetWindowShouldClose(window, glfw.GLFW_TRUE)
        needs_update = true


def framebuffer_size_callback(window: ptr[glfw.GLFWwindow], width: int, height: int) -> void:
    needs_update = true


def nrand() -> float:
    return float<-libc.rand() / float<-libc.RAND_MAX


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    glfw.glfwSetErrorCallback(error_callback)

    if glfw.glfwInit() == 0:
        return 1
    defer glfw.glfwTerminate()

    libc.srand(uint<-glfw.glfwGetTimerValue())

    let window = glfw.glfwCreateWindow(window_width, window_height, window_title, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.glfwDestroyWindow(window)

    glfw.glfwMakeContextCurrent(window)
    glfw.glfwSwapInterval(0)
    gl.mt_gl_use_glfw_loader()
    glfw.glfwSetWindowCloseCallback(window, window_close_callback)
    glfw.glfwSetKeyCallback(window, key_callback)
    glfw.glfwSetFramebufferSizeCallback(window, framebuffer_size_callback)

    while glfw.glfwWindowShouldClose(window) == 0:
        var width = 0
        var height = 0
        let r = nrand()
        let g = nrand()
        let b = nrand()
        let length = math.sqrtf(r * r + g * g + b * b)

        glfw.glfwGetFramebufferSize(window, ptr_of(width), ptr_of(height))
        gl.glViewport(0, 0, width, height)
        gl.glClearColor(r / length, g / length, b / length, 1.0)
        gl.glClear(uint<-gl.GL_COLOR_BUFFER_BIT)
        glfw.glfwSwapBuffers(window)
        needs_update = false

        let start = glfw.glfwGetTime()
        while not needs_update:
            let elapsed = glfw.glfwGetTime() - start
            if elapsed >= 1.0:
                needs_update = true
            else:
                glfw.glfwWaitEventsTimeout(1.0 - elapsed)

    return 0
