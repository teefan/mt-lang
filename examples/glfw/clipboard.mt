module examples.glfw.clipboard

import std.c.glfw as glfw
import std.c.gl as gl
import std.c.stdio as stdio

const window_width: int = 200
const window_height: int = 200
const window_title: cstr = c"Clipboard Test"
const clipboard_text: cstr = c"Hello GLFW World!"


def error_callback(error: int, description: cstr) -> void:
    return


def modifier_key() -> int:
    if glfw.glfwGetPlatform() == glfw.GLFW_PLATFORM_COCOA:
        return glfw.GLFW_MOD_SUPER
    return glfw.GLFW_MOD_CONTROL


def key_callback(window: ptr[glfw.GLFWwindow], key: int, scancode: int, action: int, mods: int) -> void:
    if action != glfw.GLFW_PRESS:
        return

    if key == glfw.GLFW_KEY_ESCAPE:
        glfw.glfwSetWindowShouldClose(window, glfw.GLFW_TRUE)
        return

    if key == glfw.GLFW_KEY_C and mods == modifier_key():
        glfw.glfwSetClipboardString(zero[ptr[glfw.GLFWwindow]], clipboard_text)
        stdio.printf(c"Setting clipboard to \"%s\"\n", clipboard_text)
        return

    if key == glfw.GLFW_KEY_V and mods == modifier_key():
        let text = glfw.glfwGetClipboardString(zero[ptr[glfw.GLFWwindow]])
        unsafe:
            if ptr[char]<-text != zero[ptr[char]]:
                stdio.printf(c"Clipboard contains \"%s\"\n", text)
            else:
                stdio.printf(c"Clipboard does not contain a string\n")


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    glfw.glfwSetErrorCallback(error_callback)

    if glfw.glfwInit() == 0:
        return 1
    defer glfw.glfwTerminate()

    let window = glfw.glfwCreateWindow(window_width, window_height, window_title, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.glfwDestroyWindow(window)

    glfw.glfwMakeContextCurrent(window)
    gl.mt_gl_use_glfw_loader()
    glfw.glfwSwapInterval(1)
    glfw.glfwSetKeyCallback(window, key_callback)
    gl.glClearColor(0.5, 0.5, 0.5, 0.0)

    while glfw.glfwWindowShouldClose(window) == 0:
        gl.glClear(uint<-gl.GL_COLOR_BUFFER_BIT)
        glfw.glfwSwapBuffers(window)
        glfw.glfwWaitEvents()

    return 0
