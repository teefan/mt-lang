module examples.idiomatic.glfw.clipboard

import std.glfw as glfw
import std.gl as gl
import std.c.stdio as stdio

const window_width: int = 200
const window_height: int = 200
const window_title: cstr = c"Clipboard Test"
const clipboard_text: cstr = c"Hello GLFW World!"


def error_callback(error: int, description: cstr) -> void:
    return


def modifier_key() -> int:
    if glfw.get_platform() == glfw.PLATFORM_COCOA:
        return glfw.MOD_SUPER
    return glfw.MOD_CONTROL


def key_callback(window: ptr[glfw.GLFWwindow], key: int, scancode: int, action: int, mods: int) -> void:
    if action != glfw.PRESS:
        return

    if key == glfw.KEY_ESCAPE:
        glfw.set_window_should_close(window, glfw.TRUE)
        return

    if key == glfw.KEY_C and mods == modifier_key():
        glfw.set_clipboard_string(zero[ptr[glfw.GLFWwindow]], clipboard_text)
        stdio.printf(c"Setting clipboard to \"%s\"\n", clipboard_text)
        return

    if key == glfw.KEY_V and mods == modifier_key():
        let text = glfw.get_clipboard_string(zero[ptr[glfw.GLFWwindow]])
        unsafe:
            if ptr[char]<-text != zero[ptr[char]]:
                stdio.printf(c"Clipboard contains \"%s\"\n", text)
            else:
                stdio.printf(c"Clipboard does not contain a string\n")


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    glfw.set_error_callback(error_callback)

    if glfw.init() == 0:
        return 1
    defer glfw.terminate()

    let window = glfw.create_window(window_width, window_height, window_title, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.destroy_window(window)

    glfw.make_context_current(window)
    gl.use_glfw_loader()
    glfw.swap_interval(1)
    glfw.set_key_callback(window, key_callback)
    gl.clear_color(0.5, 0.5, 0.5, 0.0)

    while glfw.window_should_close(window) == 0:
        gl.clear(uint<-gl.COLOR_BUFFER_BIT)
        glfw.swap_buffers(window)
        glfw.wait_events()

    return 0
