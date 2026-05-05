module examples.glfw.windows

import std.c.glfw as glfw
import std.c.gl as gl

const window_count: int = 4
const window_title: cstr = c"Multi-Window Example"
const clear_red: array[float, 4] = array[float, 4](0.95, 0.50, 0.00, 0.98)
const clear_green: array[float, 4] = array[float, 4](0.32, 0.80, 0.68, 0.74)
const clear_blue: array[float, 4] = array[float, 4](0.11, 0.16, 0.94, 0.04)

var windows: array[ptr[glfw.GLFWwindow], 4] = zero[array[ptr[glfw.GLFWwindow], 4]]


def init_window(index: int, xpos: int, ypos: int, size: int) -> bool:
    if index > 0:
        glfw.glfwWindowHint(glfw.GLFW_FOCUS_ON_SHOW, glfw.GLFW_FALSE)

    glfw.glfwWindowHint(glfw.GLFW_POSITION_X, xpos + size * (1 + (index & 1)))
    glfw.glfwWindowHint(glfw.GLFW_POSITION_Y, ypos + size * (1 + (index >> 1)))

    let window = glfw.glfwCreateWindow(size, size, window_title, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        return false

    windows[index] = window
    glfw.glfwSetInputMode(window, glfw.GLFW_STICKY_KEYS, glfw.GLFW_TRUE)
    glfw.glfwMakeContextCurrent(window)
    gl.mt_gl_use_glfw_loader()
    gl.glClearColor(clear_red[index], clear_green[index], clear_blue[index], 1.0)
    return true


def should_close(window: ptr[glfw.GLFWwindow]) -> bool:
    return glfw.glfwWindowShouldClose(window) != 0 or glfw.glfwGetKey(window, glfw.GLFW_KEY_ESCAPE) == glfw.GLFW_PRESS


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    if glfw.glfwInit() == 0:
        return 1
    defer glfw.glfwTerminate()

    glfw.glfwWindowHint(glfw.GLFW_DECORATED, glfw.GLFW_FALSE)

    let primary_monitor = glfw.glfwGetPrimaryMonitor()
    if primary_monitor == zero[ptr[glfw.GLFWmonitor]]:
        return 1

    var xpos = 0
    var ypos = 0
    var width = 0
    var height = 0
    glfw.glfwGetMonitorWorkarea(primary_monitor, ptr_of(xpos), ptr_of(ypos), ptr_of(width), ptr_of(height))

    let size = height / 5

    var index = 0
    while index < window_count:
        if not init_window(index, xpos, ypos, size):
            return 1
        index += 1

    while true:
        index = 0
        while index < window_count:
            let window = windows[index]
            glfw.glfwMakeContextCurrent(window)
            gl.mt_gl_use_glfw_loader()
            gl.glClear(gl.GL_COLOR_BUFFER_BIT)
            glfw.glfwSwapBuffers(window)

            if should_close(window):
                return 0

            index += 1

        glfw.glfwWaitEvents()
