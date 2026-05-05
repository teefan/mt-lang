module examples.idiomatic.glfw.particles

import std.glfw as glfw
import std.gl as gl
import std.c.libm as math
import std.c.libc as libc

type Mat4 = array[float, 16]

struct Vec3:
    x: float
    y: float
    z: float

struct Vertex:
    s: float
    t: float
    rgba: uint
    x: float
    y: float
    z: float

struct Particle:
    x: float
    y: float
    z: float
    vx: float
    vy: float
    vz: float
    r: float
    g: float
    b: float
    life: float
    active: bool

const particle_tex_width: int = 8
const particle_tex_height: int = 8
const floor_tex_width: int = 16
const floor_tex_height: int = 16
const particle_tex_size: int = particle_tex_width * particle_tex_height
const floor_tex_size: int = floor_tex_width * floor_tex_height

const max_particles: int = 3000
const life_span: float = 8.0
const birth_interval: float = life_span / float<-max_particles
const particle_size: float = 0.7
const gravity: float = 9.8
const velocity_base: float = 8.0
const friction: float = 0.75
const fountain_height: float = 3.0
const fountain_radius: float = 1.6
const fountain_r2: float = (fountain_radius + particle_size * 0.5) * (fountain_radius + particle_size * 0.5)
const min_delta_t: float = birth_interval * 0.5
const batch_particles: int = 70
const particle_verts: int = 4
const batch_vertex_count: int = batch_particles * particle_verts

const fountain_side_points: int = 14
const fountain_sweep_steps: int = 32
const fountain_side_count: int = fountain_side_points * 2

const window_width: int = 640
const window_height: int = 480
const window_title: cstr = c"Particle Engine"

var aspect_ratio: float = float<-window_width / float<-window_height
var wireframe: bool = false
var particle_tex_id: uint = 0
var floor_tex_id: uint = 0
var fountain_list: uint = 0
var floor_list: uint = 0
var particles: array[Particle, max_particles] = zero[array[Particle, max_particles]]
var min_age: float = 0.0
var glow_color: array[float, 4] = zero[array[float, 4]]
var glow_pos: array[float, 4] = zero[array[float, 4]]

var particle_texture: array[ubyte, particle_tex_size] = array[ubyte, particle_tex_size](
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x11, 0x22, 0x22, 0x11, 0x00, 0x00,
    0x00, 0x11, 0x33, 0x88, 0x77, 0x33, 0x11, 0x00,
    0x00, 0x22, 0x88, 0xFF, 0xEE, 0x77, 0x22, 0x00,
    0x00, 0x22, 0x77, 0xEE, 0xFF, 0x88, 0x22, 0x00,
    0x00, 0x11, 0x33, 0x77, 0x88, 0x33, 0x11, 0x00,
    0x00, 0x00, 0x11, 0x33, 0x22, 0x11, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
)

var floor_texture: array[ubyte, floor_tex_size] = array[ubyte, floor_tex_size](
    0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
    0xFF, 0xF0, 0xCC, 0xF0, 0xF0, 0xF0, 0xFF, 0xF0, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
    0xF0, 0xCC, 0xEE, 0xFF, 0xF0, 0xF0, 0xF0, 0xF0, 0x30, 0x66, 0x30, 0x30, 0x30, 0x20, 0x30, 0x30,
    0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xEE, 0xF0, 0xF0, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
    0xF0, 0xF0, 0xF0, 0xF0, 0xCC, 0xF0, 0xF0, 0xF0, 0x30, 0x30, 0x55, 0x30, 0x30, 0x44, 0x30, 0x30,
    0xF0, 0xDD, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0x33, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
    0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xFF, 0xF0, 0xF0, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x60, 0x30,
    0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0x33, 0x33, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30,
    0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x33, 0x30, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0,
    0x30, 0x30, 0x30, 0x30, 0x30, 0x20, 0x30, 0x30, 0xF0, 0xFF, 0xF0, 0xF0, 0xDD, 0xF0, 0xF0, 0xFF,
    0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x55, 0x33, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xFF, 0xF0, 0xF0,
    0x30, 0x44, 0x66, 0x30, 0x30, 0x30, 0x30, 0x30, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0,
    0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0xF0, 0xF0, 0xF0, 0xAA, 0xF0, 0xF0, 0xCC, 0xF0,
    0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0xFF, 0xF0, 0xF0, 0xF0, 0xFF, 0xF0, 0xDD, 0xF0,
    0x30, 0x30, 0x30, 0x77, 0x30, 0x30, 0x30, 0x30, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0,
    0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0,
)

var fountain_side: array[float, fountain_side_count] = array[float, fountain_side_count](
    1.2, 0.0, 1.0, 0.2, 0.41, 0.3, 0.4, 0.35,
    0.4, 1.95, 0.41, 2.0, 0.8, 2.2, 1.2, 2.4,
    1.5, 2.7, 1.55, 2.95, 1.6, 3.0, 1.0, 3.0,
    0.5, 3.0, 0.0, 3.0,
)

var fountain_normal: array[float, fountain_side_count] = array[float, fountain_side_count](
    1.0, 0.0, 0.6428, 0.7660, 0.3420, 0.9397, 1.0, 0.0,
    1.0, 0.0, 0.3420, -0.9397, 0.4226, -0.9063, 0.5000, -0.8660,
    0.7660, -0.6428, 0.9063, -0.4226, 0.0, 1.0, 0.0, 1.0,
    0.0, 1.0, 0.0, 1.0,
)


def mat4_perspective(fov_radians: float, aspect: float, near: float, far: float) -> Mat4:
    let focal_length = 1.0 / math.tanf(fov_radians * 0.5)
    return array[float, 16](
        focal_length / aspect, 0.0, 0.0, 0.0,
        0.0, focal_length, 0.0, 0.0,
        0.0, 0.0, (far + near) / (near - far), -1.0,
        0.0, 0.0, (2.0 * far * near) / (near - far), 0.0,
    )


def load_matrix(matrix: Mat4) -> void:
    var copy = matrix
    gl.load_matrixf(const_ptr_of(copy[0]))


def pack_rgba(r: float, g: float, b: float, a: float) -> uint:
    var rgba: uint = 0
    unsafe:
        let bytes = ptr[ubyte]<-ptr_of(rgba)
        read(bytes + 0) = ubyte<-(r * 255.0)
        read(bytes + 1) = ubyte<-(g * 255.0)
        read(bytes + 2) = ubyte<-(b * 255.0)
        read(bytes + 3) = ubyte<-(a * 255.0)
    return rgba


def init_particle(index: int, t: double) -> void:
    let time = float<-t

    particles[index].x = 0.0
    particles[index].y = 0.0
    particles[index].z = fountain_height

    particles[index].vz = 0.7 + (0.3 / 4096.0) * float<-(libc.rand() & 4095)
    let xy_angle = (2.0 * math.M_PI_F / 4096.0) * float<-(libc.rand() & 4095)
    particles[index].vx = 0.4 * math.cosf(xy_angle)
    particles[index].vy = 0.4 * math.sinf(xy_angle)

    let velocity = velocity_base * (0.8 + 0.1 * (math.sinf(0.5 * time) + math.sinf(1.31 * time)))
    particles[index].vx *= velocity
    particles[index].vy *= velocity
    particles[index].vz *= velocity

    particles[index].r = 0.7 + 0.3 * math.sinf(0.34 * time + 0.1)
    particles[index].g = 0.6 + 0.4 * math.sinf(0.63 * time + 1.1)
    particles[index].b = 0.6 + 0.4 * math.sinf(0.91 * time + 2.1)

    glow_pos[0] = 0.4 * math.sinf(1.34 * time)
    glow_pos[1] = 0.4 * math.sinf(3.11 * time)
    glow_pos[2] = fountain_height + 1.0
    glow_pos[3] = 1.0
    glow_color[0] = particles[index].r
    glow_color[1] = particles[index].g
    glow_color[2] = particles[index].b
    glow_color[3] = 1.0

    particles[index].life = 1.0
    particles[index].active = true


def update_particle(index: int, dt: float) -> void:
    if not particles[index].active:
        return

    particles[index].life -= dt * (1.0 / life_span)
    if particles[index].life <= 0.0:
        particles[index].active = false
        return

    particles[index].vz -= gravity * dt
    particles[index].x += particles[index].vx * dt
    particles[index].y += particles[index].vy * dt
    particles[index].z += particles[index].vz * dt

    if particles[index].vz < 0.0:
        if (particles[index].x * particles[index].x + particles[index].y * particles[index].y) < fountain_r2 and particles[index].z < (fountain_height + particle_size * 0.5):
            particles[index].vz = -friction * particles[index].vz
            particles[index].z = fountain_height + particle_size * 0.5 + friction * (fountain_height + particle_size * 0.5 - particles[index].z)
        else:
            if particles[index].z < particle_size * 0.5:
                particles[index].vz = -friction * particles[index].vz
                particles[index].z = particle_size * 0.5 + friction * (particle_size * 0.5 - particles[index].z)


def particle_engine(t: double, dt: float) -> void:
    var remaining = dt
    while remaining > 0.0:
        let delta = if remaining < min_delta_t: remaining else: min_delta_t

        var index = 0
        while index < max_particles:
            update_particle(index, delta)
            index += 1

        min_age += delta
        while min_age >= birth_interval:
            min_age -= birth_interval
            index = 0
            while index < max_particles:
                if not particles[index].active:
                    init_particle(index, t + float<-min_age)
                    update_particle(index, min_age)
                    break
                index += 1

        remaining -= delta


def draw_particles() -> void:
    var vertex_array: array[Vertex, batch_vertex_count] = zero[array[Vertex, batch_vertex_count]]
    var vertex_data = zero[const_ptr[void]]
    unsafe:
        vertex_data = const_ptr[void]<-ptr_of(vertex_array[0])

    var modelview = zero[Mat4]
    gl.get_floatv(uint<-gl.MODELVIEW_MATRIX, ptr_of(modelview[0]))

    let quad_lower_left = Vec3(
        x = (-particle_size * 0.5) * (modelview[0] + modelview[1]),
        y = (-particle_size * 0.5) * (modelview[4] + modelview[5]),
        z = (-particle_size * 0.5) * (modelview[8] + modelview[9]),
    )
    let quad_lower_right = Vec3(
        x = (particle_size * 0.5) * (modelview[0] - modelview[1]),
        y = (particle_size * 0.5) * (modelview[4] - modelview[5]),
        z = (particle_size * 0.5) * (modelview[8] - modelview[9]),
    )

    gl.depth_mask(ubyte<-gl.FALSE)
    gl.enable(uint<-gl.BLEND)
    gl.blend_func(uint<-gl.SRC_ALPHA, uint<-gl.ONE)

    if not wireframe:
        gl.enable(uint<-gl.TEXTURE_2D)
        gl.bind_texture(uint<-gl.TEXTURE_2D, particle_tex_id)

    gl.interleaved_arrays(uint<-gl.T2F_C4UB_V3F, 0, vertex_data)

    var particle_count = 0
    var vertex_index = 0
    var index = 0
    while index < max_particles:
        if particles[index].active:
            var alpha = 4.0 * particles[index].life
            if alpha > 1.0:
                alpha = 1.0
            let rgba = pack_rgba(particles[index].r, particles[index].g, particles[index].b, alpha)

            vertex_array[vertex_index + 0] = Vertex(
                s = 0.0,
                t = 0.0,
                rgba = rgba,
                x = particles[index].x + quad_lower_left.x,
                y = particles[index].y + quad_lower_left.y,
                z = particles[index].z + quad_lower_left.z,
            )
            vertex_array[vertex_index + 1] = Vertex(
                s = 1.0,
                t = 0.0,
                rgba = rgba,
                x = particles[index].x + quad_lower_right.x,
                y = particles[index].y + quad_lower_right.y,
                z = particles[index].z + quad_lower_right.z,
            )
            vertex_array[vertex_index + 2] = Vertex(
                s = 1.0,
                t = 1.0,
                rgba = rgba,
                x = particles[index].x - quad_lower_left.x,
                y = particles[index].y - quad_lower_left.y,
                z = particles[index].z - quad_lower_left.z,
            )
            vertex_array[vertex_index + 3] = Vertex(
                s = 0.0,
                t = 1.0,
                rgba = rgba,
                x = particles[index].x - quad_lower_right.x,
                y = particles[index].y - quad_lower_right.y,
                z = particles[index].z - quad_lower_right.z,
            )

            particle_count += 1
            vertex_index += particle_verts

        if particle_count >= batch_particles:
            gl.draw_arrays(uint<-gl.QUADS, 0, vertex_index)
            particle_count = 0
            vertex_index = 0

        index += 1

    if vertex_index > 0:
        gl.draw_arrays(uint<-gl.QUADS, 0, vertex_index)

    gl.disable_client_state(uint<-gl.VERTEX_ARRAY)
    gl.disable_client_state(uint<-gl.TEXTURE_COORD_ARRAY)
    gl.disable_client_state(uint<-gl.COLOR_ARRAY)
    gl.disable(uint<-gl.TEXTURE_2D)
    gl.disable(uint<-gl.BLEND)
    gl.depth_mask(ubyte<-gl.TRUE)


def draw_fountain() -> void:
    var fountain_diffuse = array[float, 4](0.7, 1.0, 1.0, 1.0)
    var fountain_specular = array[float, 4](1.0, 1.0, 1.0, 1.0)

    if fountain_list == 0:
        fountain_list = gl.gen_lists(1)
        gl.new_list(fountain_list, uint<-gl.COMPILE_AND_EXECUTE)

        gl.materialfv(uint<-gl.FRONT, uint<-gl.DIFFUSE, const_ptr_of(fountain_diffuse[0]))
        gl.materialfv(uint<-gl.FRONT, uint<-gl.SPECULAR, const_ptr_of(fountain_specular[0]))
        gl.materialf(uint<-gl.FRONT, uint<-gl.SHININESS, 12.0)

        var n = 0
        while n < fountain_side_points - 1:
            gl.begin(uint<-gl.TRIANGLE_STRIP)
            var m = 0
            while m <= fountain_sweep_steps:
                let angle = float<-m * (2.0 * math.M_PI_F / float<-fountain_sweep_steps)
                let x = math.cosf(angle)
                let y = math.sinf(angle)

                gl.normal_3f(
                    x * fountain_normal[n * 2 + 2],
                    y * fountain_normal[n * 2 + 2],
                    fountain_normal[n * 2 + 3],
                )
                gl.vertex_3f(
                    x * fountain_side[n * 2 + 2],
                    y * fountain_side[n * 2 + 2],
                    fountain_side[n * 2 + 3],
                )
                gl.normal_3f(
                    x * fountain_normal[n * 2],
                    y * fountain_normal[n * 2],
                    fountain_normal[n * 2 + 1],
                )
                gl.vertex_3f(
                    x * fountain_side[n * 2],
                    y * fountain_side[n * 2],
                    fountain_side[n * 2 + 1],
                )
                m += 1
            gl.end()
            n += 1

        gl.end_list()
        return

    gl.call_list(fountain_list)


def tessellate_floor(x1: float, y1: float, x2: float, y2: float, depth: int) -> void:
    var delta: float = 999999.0
    if depth < 5:
        let x = if math.fabsf(x1) < math.fabsf(x2): math.fabsf(x1) else: math.fabsf(x2)
        let y = if math.fabsf(y1) < math.fabsf(y2): math.fabsf(y1) else: math.fabsf(y2)
        delta = x * x + y * y

    if delta < 0.1:
        let x = (x1 + x2) * 0.5
        let y = (y1 + y2) * 0.5
        tessellate_floor(x1, y1, x, y, depth + 1)
        tessellate_floor(x, y1, x2, y, depth + 1)
        tessellate_floor(x1, y, x, y2, depth + 1)
        tessellate_floor(x, y, x2, y2, depth + 1)
        return

    gl.tex_coord_2f(x1 * 30.0, y1 * 30.0)
    gl.vertex_3f(x1 * 80.0, y1 * 80.0, 0.0)
    gl.tex_coord_2f(x2 * 30.0, y1 * 30.0)
    gl.vertex_3f(x2 * 80.0, y1 * 80.0, 0.0)
    gl.tex_coord_2f(x2 * 30.0, y2 * 30.0)
    gl.vertex_3f(x2 * 80.0, y2 * 80.0, 0.0)
    gl.tex_coord_2f(x1 * 30.0, y2 * 30.0)
    gl.vertex_3f(x1 * 80.0, y2 * 80.0, 0.0)


def draw_floor() -> void:
    var floor_diffuse = array[float, 4](1.0, 0.6, 0.6, 1.0)
    var floor_specular = array[float, 4](0.6, 0.6, 0.6, 1.0)

    if not wireframe:
        gl.enable(uint<-gl.TEXTURE_2D)
        gl.bind_texture(uint<-gl.TEXTURE_2D, floor_tex_id)

    if floor_list == 0:
        floor_list = gl.gen_lists(1)
        gl.new_list(floor_list, uint<-gl.COMPILE_AND_EXECUTE)

        gl.materialfv(uint<-gl.FRONT, uint<-gl.DIFFUSE, const_ptr_of(floor_diffuse[0]))
        gl.materialfv(uint<-gl.FRONT, uint<-gl.SPECULAR, const_ptr_of(floor_specular[0]))
        gl.materialf(uint<-gl.FRONT, uint<-gl.SHININESS, 18.0)

        gl.normal_3f(0.0, 0.0, 1.0)
        gl.begin(uint<-gl.QUADS)
        tessellate_floor(-1.0, -1.0, 0.0, 0.0, 0)
        tessellate_floor(0.0, -1.0, 1.0, 0.0, 0)
        tessellate_floor(0.0, 0.0, 1.0, 1.0, 0)
        tessellate_floor(-1.0, 0.0, 0.0, 1.0, 0)
        gl.end()

        gl.end_list()
        return

    gl.call_list(floor_list)
    gl.disable(uint<-gl.TEXTURE_2D)


def setup_lights() -> void:
    var l1pos = array[float, 4](0.0, -9.0, 8.0, 1.0)
    var l1amb = array[float, 4](0.2, 0.2, 0.2, 1.0)
    var l1dif = array[float, 4](0.8, 0.4, 0.2, 1.0)
    var l1spec = array[float, 4](1.0, 0.6, 0.2, 0.0)
    var l2pos = array[float, 4](-15.0, 12.0, 1.5, 1.0)
    var l2amb = array[float, 4](0.0, 0.0, 0.0, 1.0)
    var l2dif = array[float, 4](0.2, 0.4, 0.8, 1.0)
    var l2spec = array[float, 4](0.2, 0.6, 1.0, 0.0)
    var glow_position = glow_pos
    var glow_color_local = glow_color

    gl.lightfv(uint<-gl.LIGHT1, uint<-gl.POSITION, const_ptr_of(l1pos[0]))
    gl.lightfv(uint<-gl.LIGHT1, uint<-gl.AMBIENT, const_ptr_of(l1amb[0]))
    gl.lightfv(uint<-gl.LIGHT1, uint<-gl.DIFFUSE, const_ptr_of(l1dif[0]))
    gl.lightfv(uint<-gl.LIGHT1, uint<-gl.SPECULAR, const_ptr_of(l1spec[0]))
    gl.lightfv(uint<-gl.LIGHT2, uint<-gl.POSITION, const_ptr_of(l2pos[0]))
    gl.lightfv(uint<-gl.LIGHT2, uint<-gl.AMBIENT, const_ptr_of(l2amb[0]))
    gl.lightfv(uint<-gl.LIGHT2, uint<-gl.DIFFUSE, const_ptr_of(l2dif[0]))
    gl.lightfv(uint<-gl.LIGHT2, uint<-gl.SPECULAR, const_ptr_of(l2spec[0]))
    gl.lightfv(uint<-gl.LIGHT3, uint<-gl.POSITION, const_ptr_of(glow_position[0]))
    gl.lightfv(uint<-gl.LIGHT3, uint<-gl.DIFFUSE, const_ptr_of(glow_color_local[0]))
    gl.lightfv(uint<-gl.LIGHT3, uint<-gl.SPECULAR, const_ptr_of(glow_color_local[0]))
    gl.enable(uint<-gl.LIGHT1)
    gl.enable(uint<-gl.LIGHT2)
    gl.enable(uint<-gl.LIGHT3)


def draw_scene(t: double) -> void:
    let projection = mat4_perspective(65.0 * math.M_PI_F / 180.0, aspect_ratio, 1.0, 60.0)
    var fog_color = array[float, 4](0.1, 0.1, 0.1, 1.0)

    gl.clear_color(0.1, 0.1, 0.1, 1.0)
    gl.clear(uint<-(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT))

    gl.matrix_mode(uint<-gl.PROJECTION)
    load_matrix(projection)
    gl.matrix_mode(uint<-gl.MODELVIEW)
    gl.load_identity()

    let angle_x = 80.0
    let angle_y = 10.0 * math.sinf(float<-(0.3 * t))
    let angle_z = 10.0 * t
    gl.rotated(-angle_x, 1.0, 0.0, 0.0)
    gl.rotated(-double<-angle_y, 0.0, 1.0, 0.0)
    gl.rotated(-angle_z, 0.0, 0.0, 1.0)

    let xpos = 15.0 * math.sinf((math.M_PI_F / 180.0) * float<-angle_z) + 2.0 * math.sinf((math.M_PI_F / 180.0) * float<-(3.1 * t))
    let ypos = -15.0 * math.cosf((math.M_PI_F / 180.0) * float<-angle_z) + 2.0 * math.cosf((math.M_PI_F / 180.0) * float<-(2.9 * t))
    let zpos = 4.0 + 2.0 * math.cosf((math.M_PI_F / 180.0) * float<-(4.9 * t))
    gl.translated(-double<-xpos, -double<-ypos, -double<-zpos)

    gl.front_face(uint<-gl.CCW)
    gl.cull_face(uint<-gl.BACK)
    gl.enable(uint<-gl.CULL_FACE)

    setup_lights()
    gl.enable(uint<-gl.LIGHTING)
    gl.enable(uint<-gl.FOG)
    gl.fogi(uint<-gl.FOG_MODE, int<-gl.EXP)
    gl.fogf(uint<-gl.FOG_DENSITY, 0.05)
    gl.fogfv(uint<-gl.FOG_COLOR, const_ptr_of(fog_color[0]))

    draw_floor()

    gl.enable(uint<-gl.DEPTH_TEST)
    gl.depth_func(uint<-gl.LEQUAL)
    gl.depth_mask(ubyte<-gl.TRUE)
    draw_fountain()

    gl.disable(uint<-gl.LIGHTING)
    gl.disable(uint<-gl.FOG)
    draw_particles()
    gl.disable(uint<-gl.DEPTH_TEST)


def resize_callback(window: ptr[glfw.GLFWwindow], width: int, height: int) -> void:
    gl.viewport(0, 0, width, height)
    if height > 0:
        aspect_ratio = float<-width / float<-height
    else:
        aspect_ratio = 1.0


def key_callback(window: ptr[glfw.GLFWwindow], key: int, scancode: int, action: int, mods: int) -> void:
    if action != glfw.PRESS:
        return

    if key == glfw.KEY_ESCAPE:
        glfw.set_window_should_close(window, glfw.TRUE)
        return

    if key == glfw.KEY_W:
        wireframe = not wireframe
        if wireframe:
            gl.polygon_mode(uint<-gl.FRONT_AND_BACK, uint<-gl.LINE)
        else:
            gl.polygon_mode(uint<-gl.FRONT_AND_BACK, uint<-gl.FILL)


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
    glfw.swap_interval(1)
    glfw.set_framebuffer_size_callback(window, resize_callback)
    glfw.set_key_callback(window, key_callback)

    var framebuffer_width = 0
    var framebuffer_height = 0
    glfw.get_framebuffer_size(window, ptr_of(framebuffer_width), ptr_of(framebuffer_height))
    resize_callback(window, framebuffer_width, framebuffer_height)

    var particle_texture_data = zero[const_ptr[void]]
    var floor_texture_data = zero[const_ptr[void]]
    unsafe:
        particle_texture_data = const_ptr[void]<-ptr_of(particle_texture[0])
        floor_texture_data = const_ptr[void]<-ptr_of(floor_texture[0])

    gl.gen_textures(1, ptr_of(particle_tex_id))
    gl.bind_texture(uint<-gl.TEXTURE_2D, particle_tex_id)
    gl.pixel_storei(uint<-gl.UNPACK_ALIGNMENT, 1)
    gl.tex_parameteri(uint<-gl.TEXTURE_2D, uint<-gl.TEXTURE_WRAP_S, int<-gl.CLAMP)
    gl.tex_parameteri(uint<-gl.TEXTURE_2D, uint<-gl.TEXTURE_WRAP_T, int<-gl.CLAMP)
    gl.tex_parameteri(uint<-gl.TEXTURE_2D, uint<-gl.TEXTURE_MAG_FILTER, int<-gl.LINEAR)
    gl.tex_parameteri(uint<-gl.TEXTURE_2D, uint<-gl.TEXTURE_MIN_FILTER, int<-gl.LINEAR)
    gl.tex_image_2d(uint<-gl.TEXTURE_2D, 0, int<-gl.LUMINANCE, particle_tex_width, particle_tex_height, 0, uint<-gl.LUMINANCE, uint<-gl.UNSIGNED_BYTE, particle_texture_data)

    gl.gen_textures(1, ptr_of(floor_tex_id))
    gl.bind_texture(uint<-gl.TEXTURE_2D, floor_tex_id)
    gl.pixel_storei(uint<-gl.UNPACK_ALIGNMENT, 1)
    gl.tex_parameteri(uint<-gl.TEXTURE_2D, uint<-gl.TEXTURE_WRAP_S, int<-gl.REPEAT)
    gl.tex_parameteri(uint<-gl.TEXTURE_2D, uint<-gl.TEXTURE_WRAP_T, int<-gl.REPEAT)
    gl.tex_parameteri(uint<-gl.TEXTURE_2D, uint<-gl.TEXTURE_MAG_FILTER, int<-gl.LINEAR)
    gl.tex_parameteri(uint<-gl.TEXTURE_2D, uint<-gl.TEXTURE_MIN_FILTER, int<-gl.LINEAR)
    gl.tex_image_2d(uint<-gl.TEXTURE_2D, 0, int<-gl.LUMINANCE, floor_tex_width, floor_tex_height, 0, uint<-gl.LUMINANCE, uint<-gl.UNSIGNED_BYTE, floor_texture_data)

    if glfw.extension_supported(c"GL_EXT_separate_specular_color") != 0:
        gl.light_modeli(uint<-gl.LIGHT_MODEL_COLOR_CONTROL, int<-gl.SEPARATE_SPECULAR_COLOR)

    gl.polygon_mode(uint<-gl.FRONT_AND_BACK, uint<-gl.FILL)
    wireframe = false
    min_age = 0.0
    glfw.set_time(0.0)

    var last_time = glfw.get_time()
    while glfw.window_should_close(window) == 0:
        let now = glfw.get_time()
        let dt = float<-(now - last_time)
        last_time = now

        particle_engine(now, dt)
        draw_scene(now)

        glfw.swap_buffers(window)
        glfw.poll_events()

    return 0
