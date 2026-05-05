module examples.idiomatic.glfw.icon

import std.glfw as glfw
import std.gl as gl

const window_width: int = 200
const window_height: int = 200
const window_title: cstr = c"Window Icon"
const icon_width: int = 16
const icon_height: int = 16
const icon_pixel_count: int = icon_width * icon_height * 4

const logo: array[cstr, 16] = array[cstr, 16](
    c"................",
    c"................",
    c"...0000..0......",
    c"...0.....0......",
    c"...0.00..0......",
    c"...0..0..0......",
    c"...0000..0000...",
    c"................",
    c"................",
    c"...000..0...0...",
    c"...0....0...0...",
    c"...000..0.0.0...",
    c"...0....0.0.0...",
    c"...0....00000...",
    c"................",
    c"................",
)

const icon_reds: array[ubyte, 5] = array[ubyte, 5](0, 255, 0, 0, 255)
const icon_greens: array[ubyte, 5] = array[ubyte, 5](0, 0, 255, 0, 255)
const icon_blues: array[ubyte, 5] = array[ubyte, 5](0, 0, 0, 255, 255)
const icon_alphas: array[ubyte, 5] = array[ubyte, 5](255, 255, 255, 255, 255)

var current_icon_color: int = 0


def logo_pixel(row: int, column: int) -> char:
    unsafe:
        let row_ptr = ptr[char]<-logo[row]
        return read(row_ptr + ptr_uint<-column)


def set_icon(window: ptr[glfw.GLFWwindow], icon_color: int) -> void:
    var pixels = zero[array[ubyte, icon_pixel_count]]
    var row = 0
    while row < icon_height:
        var column = 0
        while column < icon_width:
            let base = (row * icon_width + column) * 4
            if logo_pixel(row, column) == 48:
                pixels[base + 0] = icon_reds[icon_color]
                pixels[base + 1] = icon_greens[icon_color]
                pixels[base + 2] = icon_blues[icon_color]
                pixels[base + 3] = icon_alphas[icon_color]
            column += 1
        row += 1

    var image = zero[glfw.GLFWimage]
    image.width = icon_width
    image.height = icon_height
    image.pixels = ptr_of(pixels[0])
    glfw.set_window_icon(window, 1, ptr_of(image))


def key_callback(window: ptr[glfw.GLFWwindow], key: int, scancode: int, action: int, mods: int) -> void:
    if action != glfw.PRESS:
        return

    if key == glfw.KEY_ESCAPE:
        glfw.set_window_should_close(window, glfw.TRUE)
        return

    if key == glfw.KEY_SPACE:
        current_icon_color = (current_icon_color + 1) % 5
        set_icon(window, current_icon_color)
        return

    if key == glfw.KEY_X:
        glfw.set_window_icon(window, 0, zero[const_ptr[glfw.GLFWimage]])


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    if glfw.init() == 0:
        return 1
    defer glfw.terminate()

    let window = glfw.create_window(window_width, window_height, window_title, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.destroy_window(window)

    glfw.make_context_current(window)
    gl.use_glfw_loader()
    glfw.set_key_callback(window, key_callback)
    set_icon(window, current_icon_color)

    while glfw.window_should_close(window) == 0:
        gl.clear(uint<-gl.COLOR_BUFFER_BIT)
        glfw.swap_buffers(window)
        glfw.wait_events()

    return 0
