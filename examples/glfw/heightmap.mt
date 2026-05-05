module examples.glfw.heightmap

import std.c.glfw as glfw
import std.c.gl as gl
import std.c.libm as math
import std.c.libc as libc

type Mat4 = array[float, 16]

const max_circle_size: float = 5.0
const max_displacement: float = 1.0
const displacement_sign_limit: float = 0.3
const max_iter: int = 200
const num_iter_at_a_time: int = 1

const map_size: float = 10.0
const map_num_vertices: int = 80
const map_num_total_vertices: int = map_num_vertices * map_num_vertices
const map_num_lines: int = 3 * (map_num_vertices - 1) * (map_num_vertices - 1) + 2 * (map_num_vertices - 1)
const map_line_index_count: int = 2 * map_num_lines

const window_width: int = 800
const window_height: int = 600
const window_title: cstr = c"GLFW OpenGL3 Heightmap demo"
const view_angle: float = 45.0
const aspect_ratio: float = 4.0 / 3.0
const z_near: float = 1.0
const z_far: float = 100.0

const vertex_shader_text: cstr = c<<-GLSL
    #version 150
    uniform mat4 project;
    uniform mat4 modelview;
    in float x;
    in float y;
    in float z;

    void main()
    {
       gl_Position = project * modelview * vec4(x, y, z, 1.0);
    }
GLSL
const fragment_shader_text: cstr = c<<-GLSL
    #version 150
    out vec4 color;
    void main()
    {
        color = vec4(0.2, 1.0, 0.2, 1.0);
    }
GLSL

var map_vertices: array[array[float, map_num_total_vertices], 3] = zero[array[array[float, map_num_total_vertices], 3]]
var map_line_indices: array[uint, map_line_index_count] = zero[array[uint, map_line_index_count]]
var mesh: uint = 0
var mesh_vbo: array[uint, 4] = zero[array[uint, 4]]


def mat4_identity() -> Mat4:
    return array[float, 16](
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    )


def make_shader(shader_type: gl.GLenum, source_text: cstr) -> gl.GLuint:
    let shader = gl.glCreateShader(uint<-shader_type)
    var sources = zero[array[const_ptr[gl.GLchar], 1]]
    var source_ptrs = zero[const_ptr[const_ptr[gl.GLchar]]]
    unsafe:
        sources[0] = const_ptr[gl.GLchar]<-source_text
        source_ptrs = const_ptr[const_ptr[gl.GLchar]]<-ptr_of(sources[0])
    gl.glShaderSource(shader, 1, source_ptrs, zero[const_ptr[gl.GLint]])
    gl.glCompileShader(shader)
    return shader


def make_shader_program(vs_text: cstr, fs_text: cstr) -> gl.GLuint:
    let program = gl.glCreateProgram()
    let vertex_shader = make_shader(uint<-gl.GL_VERTEX_SHADER, vs_text)
    let fragment_shader = make_shader(uint<-gl.GL_FRAGMENT_SHADER, fs_text)
    gl.glAttachShader(program, vertex_shader)
    gl.glAttachShader(program, fragment_shader)
    gl.glLinkProgram(program)
    gl.glDeleteShader(fragment_shader)
    gl.glDeleteShader(vertex_shader)
    return program


def init_map() -> void:
    let step = map_size / float<-(map_num_vertices - 1)
    var x: float = 0.0
    var z: float = 0.0
    var index = 0
    var row = 0
    while row < map_num_vertices:
        var column = 0
        while column < map_num_vertices:
            map_vertices[0][index] = x
            map_vertices[1][index] = 0.0
            map_vertices[2][index] = z
            z += step
            index += 1
            column += 1
        x += step
        z = 0.0
        row += 1

    index = 0
    row = 0
    while row < map_num_vertices - 1:
        map_line_indices[index] = uint<-((row + 1) * map_num_vertices - 1)
        map_line_indices[index + 1] = uint<-((row + 2) * map_num_vertices - 1)
        index += 2
        row += 1

    row = 0
    while row < map_num_vertices - 1:
        map_line_indices[index] = uint<-((map_num_vertices - 1) * map_num_vertices + row)
        map_line_indices[index + 1] = uint<-((map_num_vertices - 1) * map_num_vertices + row + 1)
        index += 2
        row += 1

    row = 0
    while row < map_num_vertices - 1:
        var column = 0
        while column < map_num_vertices - 1:
            let ref = row * map_num_vertices + column
            map_line_indices[index] = uint<-ref
            map_line_indices[index + 1] = uint<-(ref + 1)
            map_line_indices[index + 2] = uint<-ref
            map_line_indices[index + 3] = uint<-(ref + map_num_vertices)
            map_line_indices[index + 4] = uint<-ref
            map_line_indices[index + 5] = uint<-(ref + map_num_vertices + 1)
            index += 6
            column += 1
        row += 1


def update_map(num_iter: int) -> void:
    var remaining = num_iter
    while remaining > 0:
        let center_x = map_size * float<-libc.rand() / float<-libc.RAND_MAX
        let center_z = map_size * float<-libc.rand() / float<-libc.RAND_MAX
        let circle_size = max_circle_size * float<-libc.rand() / float<-libc.RAND_MAX
        var sign = float<-libc.rand() / float<-libc.RAND_MAX
        if sign < displacement_sign_limit:
            sign = -1.0
        else:
            sign = 1.0
        let displacement = sign * max_displacement * float<-libc.rand() / float<-libc.RAND_MAX / 2.0

        var index = 0
        while index < map_num_total_vertices:
            let dx = center_x - map_vertices[0][index]
            let dz = center_z - map_vertices[2][index]
            let pd = 2.0 * math.sqrtf(dx * dx + dz * dz) / circle_size
            if math.fabsf(pd) <= 1.0:
                let new_height = displacement + math.cosf(pd * math.M_PI_F) * displacement
                map_vertices[1][index] += new_height
            index += 1

        remaining -= 1


def make_mesh(program: uint) -> void:
    var line_index_data = zero[const_ptr[void]]
    var x_data = zero[const_ptr[void]]
    var y_data = zero[const_ptr[void]]
    var z_data = zero[const_ptr[void]]
    var x_name = zero[const_ptr[gl.GLchar]]
    var y_name = zero[const_ptr[gl.GLchar]]
    var z_name = zero[const_ptr[gl.GLchar]]
    unsafe:
        line_index_data = const_ptr[void]<-ptr_of(map_line_indices[0])
        x_data = const_ptr[void]<-ptr_of(map_vertices[0][0])
        y_data = const_ptr[void]<-ptr_of(map_vertices[1][0])
        z_data = const_ptr[void]<-ptr_of(map_vertices[2][0])
        x_name = const_ptr[gl.GLchar]<-c"x"
        y_name = const_ptr[gl.GLchar]<-c"y"
        z_name = const_ptr[gl.GLchar]<-c"z"

    gl.glGenVertexArrays(1, ptr_of(mesh))
    gl.glGenBuffers(4, ptr_of(mesh_vbo[0]))
    gl.glBindVertexArray(mesh)

    gl.glBindBuffer(uint<-gl.GL_ELEMENT_ARRAY_BUFFER, mesh_vbo[3])
    gl.glBufferData(
        uint<-gl.GL_ELEMENT_ARRAY_BUFFER,
        ptr_int<-(2 * map_num_lines * int<-size_of(uint)),
        line_index_data,
        uint<-gl.GL_STATIC_DRAW,
    )

    var attrloc = gl.glGetAttribLocation(program, x_name)
    gl.glBindBuffer(uint<-gl.GL_ARRAY_BUFFER, mesh_vbo[0])
    gl.glBufferData(
        uint<-gl.GL_ARRAY_BUFFER,
        ptr_int<-(map_num_total_vertices * int<-size_of(float)),
        x_data,
        uint<-gl.GL_STATIC_DRAW,
    )
    gl.glEnableVertexAttribArray(uint<-attrloc)
    gl.glVertexAttribPointer(uint<-attrloc, 1, uint<-gl.GL_FLOAT, ubyte<-gl.GL_FALSE, 0, zero[const_ptr[void]])

    attrloc = gl.glGetAttribLocation(program, z_name)
    gl.glBindBuffer(uint<-gl.GL_ARRAY_BUFFER, mesh_vbo[2])
    gl.glBufferData(
        uint<-gl.GL_ARRAY_BUFFER,
        ptr_int<-(map_num_total_vertices * int<-size_of(float)),
        z_data,
        uint<-gl.GL_STATIC_DRAW,
    )
    gl.glEnableVertexAttribArray(uint<-attrloc)
    gl.glVertexAttribPointer(uint<-attrloc, 1, uint<-gl.GL_FLOAT, ubyte<-gl.GL_FALSE, 0, zero[const_ptr[void]])

    attrloc = gl.glGetAttribLocation(program, y_name)
    gl.glBindBuffer(uint<-gl.GL_ARRAY_BUFFER, mesh_vbo[1])
    gl.glBufferData(
        uint<-gl.GL_ARRAY_BUFFER,
        ptr_int<-(map_num_total_vertices * int<-size_of(float)),
        y_data,
        uint<-gl.GL_DYNAMIC_DRAW,
    )
    gl.glEnableVertexAttribArray(uint<-attrloc)
    gl.glVertexAttribPointer(uint<-attrloc, 1, uint<-gl.GL_FLOAT, ubyte<-gl.GL_FALSE, 0, zero[const_ptr[void]])


def update_mesh() -> void:
    var y_data = zero[const_ptr[void]]
    unsafe:
        y_data = const_ptr[void]<-ptr_of(map_vertices[1][0])

    gl.glBindVertexArray(mesh)
    gl.glBindBuffer(uint<-gl.GL_ARRAY_BUFFER, mesh_vbo[1])
    gl.glBufferSubData(
        uint<-gl.GL_ARRAY_BUFFER,
        0,
        ptr_int<-(map_num_total_vertices * int<-size_of(float)),
        y_data,
    )


def key_callback(window: ptr[glfw.GLFWwindow], key: int, scancode: int, action: int, mods: int) -> void:
    if key == glfw.GLFW_KEY_ESCAPE:
        glfw.glfwSetWindowShouldClose(window, glfw.GLFW_TRUE)


def main(argc: int, argv: ptr[ptr[char]]) -> int:
    if glfw.glfwInit() == 0:
        return 1
    defer glfw.glfwTerminate()

    glfw.glfwWindowHint(glfw.GLFW_RESIZABLE, glfw.GLFW_FALSE)
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MAJOR, 3)
    glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MINOR, 2)
    glfw.glfwWindowHint(glfw.GLFW_OPENGL_PROFILE, glfw.GLFW_OPENGL_CORE_PROFILE)
    glfw.glfwWindowHint(glfw.GLFW_OPENGL_FORWARD_COMPAT, glfw.GLFW_TRUE)

    let window = glfw.glfwCreateWindow(window_width, window_height, window_title, zero[ptr[glfw.GLFWmonitor]], zero[ptr[glfw.GLFWwindow]])
    if window == zero[ptr[glfw.GLFWwindow]]:
        return 1
    defer glfw.glfwDestroyWindow(window)

    glfw.glfwSetKeyCallback(window, key_callback)

    glfw.glfwMakeContextCurrent(window)
    gl.mt_gl_use_glfw_loader()

    let shader_program = make_shader_program(vertex_shader_text, fragment_shader_text)
    if shader_program == 0:
        return 1
    defer gl.glDeleteProgram(shader_program)

    gl.glUseProgram(shader_program)
    var project_name = zero[const_ptr[gl.GLchar]]
    var modelview_name = zero[const_ptr[gl.GLchar]]
    unsafe:
        project_name = const_ptr[gl.GLchar]<-c"project"
        modelview_name = const_ptr[gl.GLchar]<-c"modelview"
    let uloc_project = gl.glGetUniformLocation(shader_program, project_name)
    let uloc_modelview = gl.glGetUniformLocation(shader_program, modelview_name)

    var projection_matrix = mat4_identity()
    var modelview_matrix = mat4_identity()
    let focal_length = 1.0 / math.tanf(view_angle * 0.5)
    projection_matrix[0] = focal_length / aspect_ratio
    projection_matrix[5] = focal_length
    projection_matrix[10] = (z_far + z_near) / (z_near - z_far)
    projection_matrix[11] = -1.0
    projection_matrix[14] = 2.0 * (z_far * z_near) / (z_near - z_far)
    gl.glUniformMatrix4fv(uloc_project, 1, ubyte<-gl.GL_FALSE, const_ptr_of(projection_matrix[0]))

    modelview_matrix[12] = -5.0
    modelview_matrix[13] = -5.0
    modelview_matrix[14] = -20.0
    gl.glUniformMatrix4fv(uloc_modelview, 1, ubyte<-gl.GL_FALSE, const_ptr_of(modelview_matrix[0]))

    init_map()
    make_mesh(shader_program)

    var framebuffer_width = 0
    var framebuffer_height = 0
    glfw.glfwGetFramebufferSize(window, ptr_of(framebuffer_width), ptr_of(framebuffer_height))
    gl.glViewport(0, 0, framebuffer_width, framebuffer_height)
    gl.glClearColor(0.0, 0.0, 0.0, 0.0)

    var iter = 0
    var last_update_time = glfw.glfwGetTime()

    while glfw.glfwWindowShouldClose(window) == 0:
        gl.glClear(uint<-gl.GL_COLOR_BUFFER_BIT)
        gl.glBindVertexArray(mesh)
        gl.glDrawElements(uint<-gl.GL_LINES, 2 * map_num_lines, uint<-gl.GL_UNSIGNED_INT, zero[const_ptr[void]])

        glfw.glfwSwapBuffers(window)
        glfw.glfwPollEvents()

        let now = glfw.glfwGetTime()
        if now - last_update_time > 0.2:
            if iter < max_iter:
                update_map(num_iter_at_a_time)
                update_mesh()
                iter += num_iter_at_a_time
            last_update_time = now

    return 0
