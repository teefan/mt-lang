module examples.glfw.gears

import std.c.glfw as glfw
import std.c.gl as gl
import std.c.libm as math

const window_width: int = 300
const window_height: int = 300
const window_title: cstr = c"Gears"
var view_rotx: float = 20.0
var view_roty: float = 30.0
var view_rotz: float = 0.0
var gear1: uint = 0
var gear2: uint = 0
var gear3: uint = 0
var angle: float = 0.0


def gear(inner_radius: float, outer_radius: float, width: float, teeth: int, tooth_depth: float) -> void:
    let r0 = inner_radius
    let r1 = outer_radius - tooth_depth * 0.5
    let r2 = outer_radius + tooth_depth * 0.5
    let da = 2.0 * math.M_PI_F / float<-teeth / 4.0

    gl.glShadeModel(uint<-gl.GL_FLAT)
    gl.glNormal3f(0.0, 0.0, 1.0)

    gl.glBegin(uint<-gl.GL_QUAD_STRIP)
    var index = 0
    while index <= teeth:
        let gear_angle = float<-index * 2.0 * math.M_PI_F / float<-teeth
        let cos_angle = math.cosf(gear_angle)
        let sin_angle = math.sinf(gear_angle)
        gl.glVertex3f(r0 * cos_angle, r0 * sin_angle, width * 0.5)
        gl.glVertex3f(r1 * cos_angle, r1 * sin_angle, width * 0.5)

        if index < teeth:
            let tooth_angle = gear_angle + 3.0 * da
            gl.glVertex3f(r0 * cos_angle, r0 * sin_angle, width * 0.5)
            gl.glVertex3f(r1 * math.cosf(tooth_angle), r1 * math.sinf(tooth_angle), width * 0.5)

        index += 1
    gl.glEnd()

    gl.glBegin(uint<-gl.GL_QUADS)
    index = 0
    while index < teeth:
        let gear_angle = float<-index * 2.0 * math.M_PI_F / float<-teeth
        gl.glVertex3f(r1 * math.cosf(gear_angle), r1 * math.sinf(gear_angle), width * 0.5)
        gl.glVertex3f(r2 * math.cosf(gear_angle + da), r2 * math.sinf(gear_angle + da), width * 0.5)
        gl.glVertex3f(r2 * math.cosf(gear_angle + 2.0 * da), r2 * math.sinf(gear_angle + 2.0 * da), width * 0.5)
        gl.glVertex3f(r1 * math.cosf(gear_angle + 3.0 * da), r1 * math.sinf(gear_angle + 3.0 * da), width * 0.5)
        index += 1
    gl.glEnd()

    gl.glNormal3f(0.0, 0.0, -1.0)
    gl.glBegin(uint<-gl.GL_QUAD_STRIP)
    index = 0
    while index <= teeth:
        let gear_angle = float<-index * 2.0 * math.M_PI_F / float<-teeth
        let cos_angle = math.cosf(gear_angle)
        let sin_angle = math.sinf(gear_angle)
        gl.glVertex3f(r1 * cos_angle, r1 * sin_angle, -width * 0.5)
        gl.glVertex3f(r0 * cos_angle, r0 * sin_angle, -width * 0.5)

        if index < teeth:
            let tooth_angle = gear_angle + 3.0 * da
            gl.glVertex3f(r1 * math.cosf(tooth_angle), r1 * math.sinf(tooth_angle), -width * 0.5)
            gl.glVertex3f(r0 * cos_angle, r0 * sin_angle, -width * 0.5)

        index += 1
    gl.glEnd()

    gl.glBegin(uint<-gl.GL_QUADS)
    index = 0
    while index < teeth:
        let gear_angle = float<-index * 2.0 * math.M_PI_F / float<-teeth
        gl.glVertex3f(r1 * math.cosf(gear_angle + 3.0 * da), r1 * math.sinf(gear_angle + 3.0 * da), -width * 0.5)
        gl.glVertex3f(r2 * math.cosf(gear_angle + 2.0 * da), r2 * math.sinf(gear_angle + 2.0 * da), -width * 0.5)
        gl.glVertex3f(r2 * math.cosf(gear_angle + da), r2 * math.sinf(gear_angle + da), -width * 0.5)
        gl.glVertex3f(r1 * math.cosf(gear_angle), r1 * math.sinf(gear_angle), -width * 0.5)
        index += 1
    gl.glEnd()

    gl.glBegin(uint<-gl.GL_QUAD_STRIP)
    index = 0
    while index < teeth:
        let gear_angle = float<-index * 2.0 * math.M_PI_F / float<-teeth
        let cos_angle = math.cosf(gear_angle)
        let sin_angle = math.sinf(gear_angle)
        let tooth_angle_a = gear_angle + da
        let tooth_angle_b = gear_angle + 2.0 * da
        let tooth_angle_c = gear_angle + 3.0 * da

        gl.glVertex3f(r1 * cos_angle, r1 * sin_angle, width * 0.5)
        gl.glVertex3f(r1 * cos_angle, r1 * sin_angle, -width * 0.5)

        var u = r2 * math.cosf(tooth_angle_a) - r1 * cos_angle
        var v = r2 * math.sinf(tooth_angle_a) - r1 * sin_angle
        let length = math.sqrtf(u * u + v * v)
        u /= length
        v /= length
        gl.glNormal3f(v, -u, 0.0)
        gl.glVertex3f(r2 * math.cosf(tooth_angle_a), r2 * math.sinf(tooth_angle_a), width * 0.5)
        gl.glVertex3f(r2 * math.cosf(tooth_angle_a), r2 * math.sinf(tooth_angle_a), -width * 0.5)

        gl.glNormal3f(cos_angle, sin_angle, 0.0)
        gl.glVertex3f(r2 * math.cosf(tooth_angle_b), r2 * math.sinf(tooth_angle_b), width * 0.5)
        gl.glVertex3f(r2 * math.cosf(tooth_angle_b), r2 * math.sinf(tooth_angle_b), -width * 0.5)

        u = r1 * math.cosf(tooth_angle_c) - r2 * math.cosf(tooth_angle_b)
        v = r1 * math.sinf(tooth_angle_c) - r2 * math.sinf(tooth_angle_b)
        gl.glNormal3f(v, -u, 0.0)
        gl.glVertex3f(r1 * math.cosf(tooth_angle_c), r1 * math.sinf(tooth_angle_c), width * 0.5)
        gl.glVertex3f(r1 * math.cosf(tooth_angle_c), r1 * math.sinf(tooth_angle_c), -width * 0.5)
        gl.glNormal3f(cos_angle, sin_angle, 0.0)

        index += 1

    gl.glVertex3f(r1, 0.0, width * 0.5)
    gl.glVertex3f(r1, 0.0, -width * 0.5)
    gl.glEnd()

    gl.glShadeModel(uint<-gl.GL_SMOOTH)
    gl.glBegin(uint<-gl.GL_QUAD_STRIP)
    index = 0
    while index <= teeth:
        let gear_angle = float<-index * 2.0 * math.M_PI_F / float<-teeth
        let cos_angle = math.cosf(gear_angle)
        let sin_angle = math.sinf(gear_angle)
        gl.glNormal3f(-cos_angle, -sin_angle, 0.0)
        gl.glVertex3f(r0 * cos_angle, r0 * sin_angle, -width * 0.5)
        gl.glVertex3f(r0 * cos_angle, r0 * sin_angle, width * 0.5)
        index += 1
    gl.glEnd()


def draw() -> void:
    gl.glClearColor(0.0, 0.0, 0.0, 0.0)
    gl.glClear(uint<-(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT))

    gl.glPushMatrix()
    gl.glRotatef(view_rotx, 1.0, 0.0, 0.0)
    gl.glRotatef(view_roty, 0.0, 1.0, 0.0)
    gl.glRotatef(view_rotz, 0.0, 0.0, 1.0)

    gl.glPushMatrix()
    gl.glTranslatef(-3.0, -2.0, 0.0)
    gl.glRotatef(angle, 0.0, 0.0, 1.0)
    gl.glCallList(gear1)
    gl.glPopMatrix()

    gl.glPushMatrix()
    gl.glTranslatef(3.1, -2.0, 0.0)
    gl.glRotatef(-2.0 * angle - 9.0, 0.0, 0.0, 1.0)
    gl.glCallList(gear2)
    gl.glPopMatrix()

    gl.glPushMatrix()
    gl.glTranslatef(-3.1, 4.2, 0.0)
    gl.glRotatef(-2.0 * angle - 25.0, 0.0, 0.0, 1.0)
    gl.glCallList(gear3)
    gl.glPopMatrix()

    gl.glPopMatrix()


def animate() -> void:
    angle = 100.0 * float<-glfw.glfwGetTime()


def key_callback(window: ptr[glfw.GLFWwindow], key: int, scancode: int, action: int, mods: int) -> void:
    if action != glfw.GLFW_PRESS:
        return

    if key == glfw.GLFW_KEY_Z:
        if (mods & glfw.GLFW_MOD_SHIFT) != 0:
            view_rotz -= 5.0
        else:
            view_rotz += 5.0
        return

    if key == glfw.GLFW_KEY_ESCAPE:
        glfw.glfwSetWindowShouldClose(window, glfw.GLFW_TRUE)
        return

    if key == glfw.GLFW_KEY_UP:
        view_rotx += 5.0
        return

    if key == glfw.GLFW_KEY_DOWN:
        view_rotx -= 5.0
        return

    if key == glfw.GLFW_KEY_LEFT:
        view_roty += 5.0
        return

    if key == glfw.GLFW_KEY_RIGHT:
        view_roty -= 5.0


def reshape(window: ptr[glfw.GLFWwindow], width: int, height: int) -> void:
    if width <= 0:
        return

    let aspect = float<-height / float<-width
    let znear = 5.0
    let zfar = 30.0
    let xmax = znear * 0.5

    gl.glViewport(0, 0, width, height)
    gl.glMatrixMode(uint<-gl.GL_PROJECTION)
    gl.glLoadIdentity()
    gl.glFrustum(-xmax, xmax, -xmax * aspect, xmax * aspect, znear, zfar)
    gl.glMatrixMode(uint<-gl.GL_MODELVIEW)
    gl.glLoadIdentity()
    gl.glTranslatef(0.0, 0.0, -20.0)


def init() -> void:
    var light_position = array[float, 4](5.0, 5.0, 10.0, 0.0)
    var red = array[float, 4](0.8, 0.1, 0.0, 1.0)
    var green = array[float, 4](0.0, 0.8, 0.2, 1.0)
    var blue = array[float, 4](0.2, 0.2, 1.0, 1.0)

    gl.glLightfv(uint<-gl.GL_LIGHT0, uint<-gl.GL_POSITION, const_ptr_of(light_position[0]))
    gl.glEnable(uint<-gl.GL_CULL_FACE)
    gl.glEnable(uint<-gl.GL_LIGHTING)
    gl.glEnable(uint<-gl.GL_LIGHT0)
    gl.glEnable(uint<-gl.GL_DEPTH_TEST)

    gear1 = gl.glGenLists(1)
    gl.glNewList(gear1, uint<-gl.GL_COMPILE)
    gl.glMaterialfv(uint<-gl.GL_FRONT, uint<-gl.GL_AMBIENT_AND_DIFFUSE, const_ptr_of(red[0]))
    gear(1.0, 4.0, 1.0, 20, 0.7)
    gl.glEndList()

    gear2 = gl.glGenLists(1)
    gl.glNewList(gear2, uint<-gl.GL_COMPILE)
    gl.glMaterialfv(uint<-gl.GL_FRONT, uint<-gl.GL_AMBIENT_AND_DIFFUSE, const_ptr_of(green[0]))
    gear(0.5, 2.0, 2.0, 10, 0.7)
    gl.glEndList()

    gear3 = gl.glGenLists(1)
    gl.glNewList(gear3, uint<-gl.GL_COMPILE)
    gl.glMaterialfv(uint<-gl.GL_FRONT, uint<-gl.GL_AMBIENT_AND_DIFFUSE, const_ptr_of(blue[0]))
    gear(1.3, 2.0, 0.5, 10, 0.7)
    gl.glEndList()

    gl.glEnable(uint<-gl.GL_NORMALIZE)


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    if glfw.glfwInit() == 0:
        return 1
    defer glfw.glfwTerminate()

    glfw.glfwWindowHint(glfw.GLFW_DEPTH_BITS, 16)
    glfw.glfwWindowHint(glfw.GLFW_TRANSPARENT_FRAMEBUFFER, glfw.GLFW_TRUE)

    let window = glfw.glfwCreateWindow(window_width, window_height, window_title, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.glfwDestroyWindow(window)

    glfw.glfwSetFramebufferSizeCallback(window, reshape)
    glfw.glfwSetKeyCallback(window, key_callback)

    glfw.glfwMakeContextCurrent(window)
    gl.mt_gl_use_glfw_loader()
    glfw.glfwSwapInterval(1)

    var framebuffer_width = 0
    var framebuffer_height = 0
    glfw.glfwGetFramebufferSize(window, ptr_of(framebuffer_width), ptr_of(framebuffer_height))
    reshape(window, framebuffer_width, framebuffer_height)
    init()

    while glfw.glfwWindowShouldClose(window) == 0:
        draw()
        animate()
        glfw.glfwSwapBuffers(window)
        glfw.glfwPollEvents()

    return 0
