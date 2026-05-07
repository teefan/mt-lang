module examples.idiomatic.glfw.clipboard

import std.glfw as glfw
import std.gl as gl
import std.io as io
import std.str as text

const window_width: int = 200
const window_height: int = 200
const window_title: cstr = c"Clipboard Test"
const clipboard_text: cstr = c"Hello GLFW World!"


def error_callback(_error: int, _description: cstr) -> void:
    return


def modifier_key() -> int:
    if glfw.get_platform() == glfw.PLATFORM_COCOA:
        return glfw.MOD_SUPER
    return glfw.MOD_CONTROL


def key_callback(window: ptr[glfw.GLFWwindow], key: int, _scancode: int, action: int, mods: int) -> void:
    if action != glfw.PRESS:
        return

    if key == glfw.KEY_ESCAPE:
        glfw.set_window_should_close(window, glfw.TRUE)
        return

    if key == glfw.KEY_C and mods == modifier_key():
        glfw.set_clipboard_string(zero[ptr[glfw.GLFWwindow]], clipboard_text)
        io.println(f"Setting clipboard to \"#{text.cstr_as_str(clipboard_text)}\"")
        return

    if key == glfw.KEY_V and mods == modifier_key():
        let clipboard = glfw.get_clipboard_string(zero[ptr[glfw.GLFWwindow]])
        if clipboard == null:
            io.println("Clipboard does not contain a string")
            return

        io.println(f"Clipboard contains \"#{text.cstr_as_str(cstr<-clipboard)}\"")


def main() -> int:
    glfw.set_error_callback(error_callback)

    if glfw.init() == 0:
        return 1
    defer glfw.terminate()

    let window = glfw.create_window(window_width, window_height, window_title, null, null)
    if window == null:
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
