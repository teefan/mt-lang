module examples.idiomatic.glfw.timeout

import std.glfw as glfw
import std.gl as gl
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
    if key == glfw.KEY_ESCAPE and action == glfw.PRESS:
        glfw.set_window_should_close(window, glfw.TRUE)
        needs_update = true


def framebuffer_size_callback(window: ptr[glfw.GLFWwindow], width: int, height: int) -> void:
    needs_update = true


def nrand() -> float:
    return float<-libc.rand() / float<-libc.RAND_MAX


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    glfw.set_error_callback(error_callback)

    if glfw.init() == 0:
        return 1
    defer glfw.terminate()

    libc.srand(uint<-glfw.get_timer_value())

    let window = glfw.create_window(window_width, window_height, window_title, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.destroy_window(window)

    glfw.make_context_current(window)
    glfw.swap_interval(0)
    gl.use_glfw_loader()
    glfw.set_window_close_callback(window, window_close_callback)
    glfw.set_key_callback(window, key_callback)
    glfw.set_framebuffer_size_callback(window, framebuffer_size_callback)

    while glfw.window_should_close(window) == 0:
        var width = 0
        var height = 0
        let r = nrand()
        let g = nrand()
        let b = nrand()
        let length = math.sqrtf(r * r + g * g + b * b)

        glfw.get_framebuffer_size(window, ptr_of(width), ptr_of(height))
        gl.viewport(0, 0, width, height)
        gl.clear_color(r / length, g / length, b / length, 1.0)
        gl.clear(uint<-gl.COLOR_BUFFER_BIT)
        glfw.swap_buffers(window)
        needs_update = false

        let start = glfw.get_time()
        while not needs_update:
            let elapsed = glfw.get_time() - start
            if elapsed >= 1.0:
                needs_update = true
            else:
                glfw.wait_events_timeout(1.0 - elapsed)

    return 0
