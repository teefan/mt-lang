module examples.sdl3.opengl.triangle

import std.c.sdl3 as sdl
import std.c.gl as gl
import std.c.libm as math

type Mat4 = array[float, 16]

const window_width: int = 640
const window_height: int = 480
const window_title: cstr = c"examples/sdl3/opengl/triangle"
const window_flags: ptr_uint = sdl.SDL_WINDOW_OPENGL | sdl.SDL_WINDOW_RESIZABLE
var positions: array[float, 6] = array[float, 6](
    -0.6, -0.4,
    0.6, -0.4,
    0.0, 0.6,
)
var colors: array[float, 9] = array[float, 9](
    1.0, 0.0, 0.0,
    0.0, 1.0, 0.0,
    0.0, 0.0, 1.0,
)
const vertex_shader_text: cstr = c<<-GLSL
    #version 330
    uniform mat4 MVP;
    in vec3 vCol;
    in vec2 vPos;
    out vec3 color;
    void main()
    {
        gl_Position = MVP * vec4(vPos, 0.0, 1.0);
        color = vCol;
    }
GLSL
const fragment_shader_text: cstr = c<<-GLSL
    #version 330
    in vec3 color;
    out vec4 fragment;
    void main()
    {
        fragment = vec4(color, 1.0);
    }
GLSL


def pump_events() -> bool:
    var event = zero[sdl.SDL_Event]

    while sdl.SDL_PollEvent(ptr_of(event)):
        if event.type_ == uint<-sdl.SDL_EventType.SDL_EVENT_QUIT:
            return false

        if event.type_ == uint<-sdl.SDL_EventType.SDL_EVENT_WINDOW_CLOSE_REQUESTED:
            return false

        if event.type_ == uint<-sdl.SDL_EventType.SDL_EVENT_KEY_DOWN and event.key.scancode == sdl.SDL_Scancode.SDL_SCANCODE_ESCAPE and event.key.down:
            return false

    return true


def mat4_ortho(left: float, right: float, bottom: float, top: float, near: float, far: float) -> Mat4:
    return array[float, 16](
        2.0 / (right - left), 0.0, 0.0, 0.0,
        0.0, 2.0 / (top - bottom), 0.0, 0.0,
        0.0, 0.0, -2.0 / (far - near), 0.0,
        -((right + left) / (right - left)), -((top + bottom) / (top - bottom)), -((far + near) / (far - near)), 1.0,
    )


def mat4_rotate_z(angle: float) -> Mat4:
    let cosine = math.cosf(angle)
    let sine = math.sinf(angle)
    return array[float, 16](
        cosine, sine, 0.0, 0.0,
        -sine, cosine, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    )


def mat4_mul(lhs: Mat4, rhs: Mat4) -> Mat4:
    var result = zero[Mat4]
    var column = 0
    while column < 4:
        var row = 0
        while row < 4:
            var value: float = 0.0
            var index = 0
            while index < 4:
                value += lhs[row + index * 4] * rhs[index + column * 4]
                index += 1
            result[row + column * 4] = value
            row += 1
        column += 1
    return result


def build_shader(shader_type: gl.GLenum, source_text: cstr) -> gl.GLuint:
    let shader = gl.glCreateShader(uint<-shader_type)
    var sources = zero[array[const_ptr[gl.GLchar], 1]]
    var source_ptrs = zero[const_ptr[const_ptr[gl.GLchar]]]
    unsafe:
        sources[0] = const_ptr[gl.GLchar]<-source_text
        source_ptrs = const_ptr[const_ptr[gl.GLchar]]<-ptr_of(sources[0])
    gl.glShaderSource(shader, 1, source_ptrs, zero[const_ptr[gl.GLint]])
    gl.glCompileShader(shader)
    return shader


def app_main(argc: int, argv: ptr[ptr[char]]) -> int:
    sdl.SDL_SetAppMetadata(c"Example SDL3 OpenGL Triangle", c"1.0", c"com.example.sdl3-opengl-triangle")

    if not sdl.SDL_Init(sdl.SDL_INIT_VIDEO):
        return 1
    defer sdl.SDL_Quit()

    if not sdl.SDL_GL_SetAttribute(sdl.SDL_GLAttr.SDL_GL_CONTEXT_MAJOR_VERSION, 3):
        return 1
    if not sdl.SDL_GL_SetAttribute(sdl.SDL_GLAttr.SDL_GL_CONTEXT_MINOR_VERSION, 3):
        return 1
    if not sdl.SDL_GL_SetAttribute(sdl.SDL_GLAttr.SDL_GL_CONTEXT_PROFILE_MASK, sdl.SDL_GL_CONTEXT_PROFILE_CORE):
        return 1

    let window = sdl.SDL_CreateWindow(window_title, window_width, window_height, window_flags)
    if window == zero[ptr[sdl.SDL_Window]]:
        return 1
    defer sdl.SDL_DestroyWindow(window)

    let context = sdl.SDL_GL_CreateContext(window)
    if context == zero[ptr[sdl.SDL_GLContextState]]:
        return 1
    defer sdl.SDL_GL_DestroyContext(context)

    if not sdl.SDL_GL_MakeCurrent(window, context):
        return 1

    gl.mt_gl_use_sdl_loader()
    defer gl.mt_gl_reset_loader()

    if not sdl.SDL_GL_SetSwapInterval(1):
        return 1

    var position_buffer: gl.GLuint = 0
    gl.glGenBuffers(1, ptr_of(position_buffer))
    gl.glBindBuffer(uint<-gl.GL_ARRAY_BUFFER, position_buffer)
    unsafe:
        gl.glBufferData(uint<-gl.GL_ARRAY_BUFFER, ptr_int<-(6 * int<-size_of(float)), const_ptr[void]<-ptr_of(positions[0]), uint<-gl.GL_STATIC_DRAW)

    var color_buffer: gl.GLuint = 0
    gl.glGenBuffers(1, ptr_of(color_buffer))
    gl.glBindBuffer(uint<-gl.GL_ARRAY_BUFFER, color_buffer)
    unsafe:
        gl.glBufferData(uint<-gl.GL_ARRAY_BUFFER, ptr_int<-(9 * int<-size_of(float)), const_ptr[void]<-ptr_of(colors[0]), uint<-gl.GL_STATIC_DRAW)

    let vertex_shader = build_shader(uint<-gl.GL_VERTEX_SHADER, vertex_shader_text)
    let fragment_shader = build_shader(uint<-gl.GL_FRAGMENT_SHADER, fragment_shader_text)

    let program = gl.glCreateProgram()
    gl.glAttachShader(program, vertex_shader)
    gl.glAttachShader(program, fragment_shader)
    gl.glLinkProgram(program)

    var mvp_name = zero[const_ptr[gl.GLchar]]
    var vpos_name = zero[const_ptr[gl.GLchar]]
    var vcol_name = zero[const_ptr[gl.GLchar]]
    unsafe:
        mvp_name = const_ptr[gl.GLchar]<-c"MVP"
        vpos_name = const_ptr[gl.GLchar]<-c"vPos"
        vcol_name = const_ptr[gl.GLchar]<-c"vCol"

    let mvp_location = gl.glGetUniformLocation(program, mvp_name)
    let vpos_location = gl.glGetAttribLocation(program, vpos_name)
    let vcol_location = gl.glGetAttribLocation(program, vcol_name)

    var vertex_array: gl.GLuint = 0
    gl.glGenVertexArrays(1, ptr_of(vertex_array))
    gl.glBindVertexArray(vertex_array)

    gl.glBindBuffer(uint<-gl.GL_ARRAY_BUFFER, position_buffer)
    gl.glEnableVertexAttribArray(uint<-vpos_location)
    gl.glVertexAttribPointer(uint<-vpos_location, 2, uint<-gl.GL_FLOAT, ubyte<-gl.GL_FALSE, 0, zero[const_ptr[void]])

    gl.glBindBuffer(uint<-gl.GL_ARRAY_BUFFER, color_buffer)
    gl.glEnableVertexAttribArray(uint<-vcol_location)
    gl.glVertexAttribPointer(uint<-vcol_location, 3, uint<-gl.GL_FLOAT, ubyte<-gl.GL_FALSE, 0, zero[const_ptr[void]])

    while pump_events():
        var width = window_width
        var height = window_height
        if not sdl.SDL_GetWindowSizeInPixels(window, ptr_of(width), ptr_of(height)):
            return 1
        if height == 0:
            height = 1

        let ratio = float<-width / float<-height
        let model = mat4_rotate_z(float<-sdl.SDL_GetTicks() / 1000.0)
        let projection = mat4_ortho(-ratio, ratio, -1.0, 1.0, 1.0, -1.0)
        var mvp = mat4_mul(projection, model)

        gl.glViewport(0, 0, width, height)
        gl.glClear(uint<-gl.GL_COLOR_BUFFER_BIT)
        gl.glUseProgram(program)
        unsafe:
            gl.glUniformMatrix4fv(mvp_location, 1, ubyte<-gl.GL_FALSE, const_ptr[gl.GLfloat]<-ptr_of(mvp[0]))
        gl.glBindVertexArray(vertex_array)
        gl.glDrawArrays(uint<-gl.GL_TRIANGLES, 0, 3)

        sdl.SDL_GL_SwapWindow(window)

    return 0


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    return sdl.SDL_RunApp(argc, argv, app_main, null)
