module examples.glfw.iconify

import std.c.glfw as glfw
import std.c.gl as gl
import std.c.libc as libc
import std.c.stdio as stdio

var windowed_xpos: int = 0
var windowed_ypos: int = 0
var windowed_width: int = 640
var windowed_height: int = 480


def cstr_eq(left: cstr, right: cstr) -> bool:
    unsafe:
        let left_ptr = ptr[char]<-left
        let right_ptr = ptr[char]<-right
        var index: ptr_uint = 0
        while true:
            let lhs = read(left_ptr + index)
            let rhs = read(right_ptr + index)
            if lhs != rhs:
                return false
            if lhs == zero[char]:
                return true
            index += 1


def usage(program_name: cstr) -> void:
    stdio.printf(c"Usage: %s [-a] [-f] [-h]\n", program_name)
    stdio.printf(c"Options:\n")
    stdio.printf(c"  -a create windows for all monitors\n")
    stdio.printf(c"  -f create full screen window(s)\n")
    stdio.printf(c"  -h show this help\n")


def error_callback(error: int, description: cstr) -> void:
    stdio.printf(c"Error: %s\n", description)


def key_callback(window: ptr[glfw.GLFWwindow], key: int, scancode: int, action: int, mods: int) -> void:
    let action_text = if action == glfw.GLFW_PRESS: c"pressed" else: c"released"
    stdio.printf(c"%0.2f Key %s\n", glfw.glfwGetTime(), action_text)

    if action != glfw.GLFW_PRESS:
        return

    if key == glfw.GLFW_KEY_I:
        glfw.glfwIconifyWindow(window)
        return

    if key == glfw.GLFW_KEY_M:
        glfw.glfwMaximizeWindow(window)
        return

    if key == glfw.GLFW_KEY_R:
        glfw.glfwRestoreWindow(window)
        return

    if key == glfw.GLFW_KEY_ESCAPE:
        glfw.glfwSetWindowShouldClose(window, glfw.GLFW_TRUE)
        return

    if key == glfw.GLFW_KEY_A:
        let value = if glfw.glfwGetWindowAttrib(window, glfw.GLFW_AUTO_ICONIFY) == 0: glfw.GLFW_TRUE else: glfw.GLFW_FALSE
        glfw.glfwSetWindowAttrib(window, glfw.GLFW_AUTO_ICONIFY, value)
        return

    if key == glfw.GLFW_KEY_B:
        let value = if glfw.glfwGetWindowAttrib(window, glfw.GLFW_RESIZABLE) == 0: glfw.GLFW_TRUE else: glfw.GLFW_FALSE
        glfw.glfwSetWindowAttrib(window, glfw.GLFW_RESIZABLE, value)
        return

    if key == glfw.GLFW_KEY_D:
        let value = if glfw.glfwGetWindowAttrib(window, glfw.GLFW_DECORATED) == 0: glfw.GLFW_TRUE else: glfw.GLFW_FALSE
        glfw.glfwSetWindowAttrib(window, glfw.GLFW_DECORATED, value)
        return

    if key == glfw.GLFW_KEY_F:
        let value = if glfw.glfwGetWindowAttrib(window, glfw.GLFW_FLOATING) == 0: glfw.GLFW_TRUE else: glfw.GLFW_FALSE
        glfw.glfwSetWindowAttrib(window, glfw.GLFW_FLOATING, value)
        return

    if (key == glfw.GLFW_KEY_F11 or key == glfw.GLFW_KEY_ENTER) and mods == glfw.GLFW_MOD_ALT:
        if glfw.glfwGetWindowMonitor(window) != zero[ptr[glfw.GLFWmonitor]]:
            glfw.glfwSetWindowMonitor(window, zero[ptr[glfw.GLFWmonitor]], windowed_xpos, windowed_ypos, windowed_width, windowed_height, 0)
            return

        let monitor = glfw.glfwGetPrimaryMonitor()
        if monitor == zero[ptr[glfw.GLFWmonitor]]:
            return

        let mode_ptr = glfw.glfwGetVideoMode(monitor)
        if mode_ptr == zero[const_ptr[glfw.GLFWvidmode]]:
            return

        unsafe:
            let mode = read(mode_ptr)
            glfw.glfwGetWindowPos(window, ptr_of(windowed_xpos), ptr_of(windowed_ypos))
            glfw.glfwGetWindowSize(window, ptr_of(windowed_width), ptr_of(windowed_height))
            glfw.glfwSetWindowMonitor(window, monitor, 0, 0, mode.width, mode.height, mode.refreshRate)


def window_size_callback(window: ptr[glfw.GLFWwindow], width: int, height: int) -> void:
    stdio.printf(c"%0.2f Window resized to %ix%i\n", glfw.glfwGetTime(), width, height)


def framebuffer_size_callback(window: ptr[glfw.GLFWwindow], width: int, height: int) -> void:
    stdio.printf(c"%0.2f Framebuffer resized to %ix%i\n", glfw.glfwGetTime(), width, height)


def window_focus_callback(window: ptr[glfw.GLFWwindow], focused: int) -> void:
    let state = if focused != 0: c"focused" else: c"defocused"
    stdio.printf(c"%0.2f Window %s\n", glfw.glfwGetTime(), state)


def window_iconify_callback(window: ptr[glfw.GLFWwindow], iconified: int) -> void:
    let state = if iconified != 0: c"iconified" else: c"uniconified"
    stdio.printf(c"%0.2f Window %s\n", glfw.glfwGetTime(), state)


def window_maximize_callback(window: ptr[glfw.GLFWwindow], maximized: int) -> void:
    let state = if maximized != 0: c"maximized" else: c"unmaximized"
    stdio.printf(c"%0.2f Window %s\n", glfw.glfwGetTime(), state)


def window_refresh_callback(window: ptr[glfw.GLFWwindow]) -> void:
    stdio.printf(c"%0.2f Window refresh\n", glfw.glfwGetTime())
    glfw.glfwMakeContextCurrent(window)
    gl.mt_gl_use_glfw_loader()
    gl.glClear(gl.GL_COLOR_BUFFER_BIT)
    glfw.glfwSwapBuffers(window)


def create_window(monitor: ptr[glfw.GLFWmonitor]) -> ptr[glfw.GLFWwindow]:
    var width = windowed_width
    var height = windowed_height

    if monitor != zero[ptr[glfw.GLFWmonitor]]:
        let mode_ptr = glfw.glfwGetVideoMode(monitor)
        if mode_ptr == zero[const_ptr[glfw.GLFWvidmode]]:
            return zero[ptr[glfw.GLFWwindow]]

        unsafe:
            let mode = read(mode_ptr)
            glfw.glfwWindowHint(glfw.GLFW_REFRESH_RATE, mode.refreshRate)
            glfw.glfwWindowHint(glfw.GLFW_RED_BITS, mode.redBits)
            glfw.glfwWindowHint(glfw.GLFW_GREEN_BITS, mode.greenBits)
            glfw.glfwWindowHint(glfw.GLFW_BLUE_BITS, mode.blueBits)
            width = mode.width
            height = mode.height

    let window = glfw.glfwCreateWindow(width, height, c"Iconify", monitor, zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        return zero[ptr[glfw.GLFWwindow]]

    glfw.glfwMakeContextCurrent(window)
    gl.mt_gl_use_glfw_loader()
    return window


def destroy_windows(windows: ptr[ptr[glfw.GLFWwindow]], window_count: int) -> void:
    unsafe:
        var index = 0
        while index < window_count:
            let window = read(windows + ptr_uint<-index)
            if window != zero[ptr[glfw.GLFWwindow]]:
                glfw.glfwDestroyWindow(window)
            index += 1
        libc.free(ptr[void]?<-windows)


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    var fullscreen = glfw.GLFW_FALSE
    var all_monitors = glfw.GLFW_FALSE

    unsafe:
        var arg = 1
        while arg < argc:
            let flag = cstr<-read(argv + ptr_uint<-arg)
            if cstr_eq(flag, c"-a"):
                all_monitors = glfw.GLFW_TRUE
            elif cstr_eq(flag, c"-f"):
                fullscreen = glfw.GLFW_TRUE
            elif cstr_eq(flag, c"-h"):
                let program_name = if argc > 0: cstr<-read(argv) else: c"iconify"
                usage(program_name)
                return 0
            else:
                let program_name = if argc > 0: cstr<-read(argv) else: c"iconify"
                usage(program_name)
                return 1
            arg += 1

    glfw.glfwSetErrorCallback(error_callback)
    if glfw.glfwInit() == 0:
        return 1
    defer glfw.glfwTerminate()

    var window_count = 1
    if fullscreen != 0 and all_monitors != 0:
        var monitor_count = 0
        let monitors = glfw.glfwGetMonitors(ptr_of(monitor_count))
        if monitors == zero[ptr[ptr[glfw.GLFWmonitor]]] or monitor_count <= 0:
            return 1
        window_count = monitor_count

    let allocated = libc.calloc(ptr_uint<-window_count, ptr_uint<-size_of(ptr[glfw.GLFWwindow]))
    if allocated == null:
        return 1

    var windows = zero[ptr[ptr[glfw.GLFWwindow]]]
    unsafe:
        windows = ptr[ptr[glfw.GLFWwindow]]<-allocated
    defer destroy_windows(windows, window_count)

    if fullscreen != 0 and all_monitors != 0:
        var monitor_count = 0
        let monitors = glfw.glfwGetMonitors(ptr_of(monitor_count))
        if monitors == zero[ptr[ptr[glfw.GLFWmonitor]]]:
            return 1

        unsafe:
            var index = 0
            while index < monitor_count:
                read(windows + ptr_uint<-index) = create_window(read(monitors + ptr_uint<-index))
                if read(windows + ptr_uint<-index) == zero[ptr[glfw.GLFWwindow]]:
                    return 1
                index += 1
    else:
        let monitor = if fullscreen != 0: glfw.glfwGetPrimaryMonitor() else: zero[ptr[glfw.GLFWmonitor]]
        unsafe:
            read(windows) = create_window(monitor)
            if read(windows) == zero[ptr[glfw.GLFWwindow]]:
                return 1

    unsafe:
        var index = 0
        while index < window_count:
            let window = read(windows + ptr_uint<-index)
            glfw.glfwSetKeyCallback(window, key_callback)
            glfw.glfwSetFramebufferSizeCallback(window, framebuffer_size_callback)
            glfw.glfwSetWindowSizeCallback(window, window_size_callback)
            glfw.glfwSetWindowFocusCallback(window, window_focus_callback)
            glfw.glfwSetWindowIconifyCallback(window, window_iconify_callback)
            glfw.glfwSetWindowMaximizeCallback(window, window_maximize_callback)
            glfw.glfwSetWindowRefreshCallback(window, window_refresh_callback)
            window_refresh_callback(window)

            let iconified = if glfw.glfwGetWindowAttrib(window, glfw.GLFW_ICONIFIED) != 0: c"iconified" else: c"restored"
            let focused = if glfw.glfwGetWindowAttrib(window, glfw.GLFW_FOCUSED) != 0: c"focused" else: c"defocused"
            stdio.printf(c"Window is %s and %s\n", iconified, focused)

            index += 1

    while true:
        glfw.glfwWaitEvents()

        unsafe:
            var index = 0
            while index < window_count:
                if glfw.glfwWindowShouldClose(read(windows + ptr_uint<-index)) != 0:
                    return 0
                index += 1
