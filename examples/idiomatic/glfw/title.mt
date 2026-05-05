module examples.idiomatic.glfw.title

import std.glfw as glfw
import std.gl as gl

const window_width: int = 400
const window_height: int = 400
const window_title_utf8: cstr = c"English 日本語 русский язык 官話"


def error_callback(error: int, description: cstr) -> void:
    return


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    glfw.set_error_callback(error_callback)

    if glfw.init() == 0:
        return 1
    defer glfw.terminate()

    let window = glfw.create_window(window_width, window_height, window_title_utf8, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.destroy_window(window)

    glfw.make_context_current(window)
    gl.use_glfw_loader()
    glfw.swap_interval(1)

    while glfw.window_should_close(window) == 0:
        gl.clear(uint<-gl.COLOR_BUFFER_BIT)
        glfw.swap_buffers(window)
        glfw.wait_events()

    return 0
