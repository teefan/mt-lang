import std.math as math
import std.c.raylib as c
import std.raylib as rl
import std.rlgl as rlgl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_POINTS: int = 10000000
const MIN_POINTS: int = 1000
const RANDOM_SCALE: int = 100000


function gen_mesh_points(num_points: int) -> rl.Mesh:
    let raw_vertices = c.MemAlloc(uint<-(num_points * 3 * int<-size_of(float))) else:
        fatal("could not allocate point mesh vertices")
    let vertices = unsafe: ptr[float]<-raw_vertices
    let raw_colors = c.MemAlloc(uint<-(num_points * 4 * int<-size_of(ubyte))) else:
        fatal("could not allocate point mesh colors")
    let colors = unsafe: ptr[ubyte]<-raw_colors

    var mesh = rl.Mesh(
        triangleCount = 1,
        vertexCount = num_points,
        vertices = vertices,
        texcoords = zero[ptr[float]],
        texcoords2 = zero[ptr[float]],
        normals = zero[ptr[float]],
        tangents = zero[ptr[float]],
        colors = colors,
        indices = null,
        boneCount = 0,
        boneIndices = zero[ptr[ubyte]],
        boneWeights = zero[ptr[float]],
        animVertices = zero[ptr[float]],
        animNormals = zero[ptr[float]],
        vaoId = 0,
        vboId = zero[ptr[uint]]
    )

    var index = 0
    while index < num_points:
        let theta = (rl.PI * float<-rl.get_random_value(0, RANDOM_SCALE)) / float<-RANDOM_SCALE
        let phi = ((2.0 * rl.PI) * float<-rl.get_random_value(0, RANDOM_SCALE)) / float<-RANDOM_SCALE
        let radius = (10.0 * float<-rl.get_random_value(0, RANDOM_SCALE)) / float<-RANDOM_SCALE

        unsafe:
            read(vertices + ptr_uint<-(index * 3 + 0)) = float<-(double<-radius * math.sin(double<-theta) * math.cos(double<-phi))
            read(vertices + ptr_uint<-(index * 3 + 1)) = float<-(double<-radius * math.sin(double<-theta) * math.sin(double<-phi))
            read(vertices + ptr_uint<-(index * 3 + 2)) = float<-(double<-radius * math.cos(double<-theta))

        let color = rl.color_from_hsv(radius * 360.0, 1.0, 1.0)
        unsafe:
            read(colors + ptr_uint<-(index * 4 + 0)) = color.r
            read(colors + ptr_uint<-(index * 4 + 1)) = color.g
            read(colors + ptr_uint<-(index * 4 + 2)) = color.b
            read(colors + ptr_uint<-(index * 4 + 3)) = color.a

        index += 1

    rl.upload_mesh(ptr_of(mesh), false)
    return mesh


function draw_model_points(model: rl.Model, position: rl.Vector3, scale: float, tint: rl.Color) -> void:
    rlgl.enable_point_mode()
    rlgl.disable_backface_culling()
    rl.draw_model(model, position, scale, tint)
    rlgl.enable_backface_culling()
    rlgl.disable_point_mode()


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - point rendering")
    defer rl.close_window()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 3.0, y = 3.0, z = 3.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
    var use_draw_model_points = true
    var num_points_changed = false
    var num_points = 1000

    var mesh = gen_mesh_points(num_points)
    var model = rl.load_model_from_mesh(mesh)
    defer rl.unload_model(model)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            use_draw_model_points = not use_draw_model_points
        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            let increased_points = num_points * 10
            if increased_points > MAX_POINTS:
                num_points = MAX_POINTS
            else:
                num_points = increased_points
            num_points_changed = true
        if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            let reduced_points = num_points / 10
            if reduced_points < MIN_POINTS:
                num_points = MIN_POINTS
            else:
                num_points = reduced_points
            num_points_changed = true

        if num_points_changed:
            rl.unload_model(model)
            mesh = gen_mesh_points(num_points)
            model = rl.load_model_from_mesh(mesh)
            num_points_changed = false

        let point_count_text = rl.text_format("Point Count: %d", num_points)
        let draw_mode_text = if use_draw_model_points: "Using: DrawModelPoints()" else: "Using: DrawPoint3D()"
        let draw_mode_color = if use_draw_model_points: rl.GREEN else: rl.RED

        rl.begin_drawing()
        rl.clear_background(rl.BLACK)

        rl.begin_mode_3d(camera)
        if use_draw_model_points:
            draw_model_points(model, position, 1.0, rl.WHITE)
        else:
            var index = 0
            while index < num_points:
                let pos = rl.Vector3(
                    x = unsafe: read(mesh.vertices + ptr_uint<-(index * 3 + 0)),
                    y = unsafe: read(mesh.vertices + ptr_uint<-(index * 3 + 1)),
                    z = unsafe: read(mesh.vertices + ptr_uint<-(index * 3 + 2))
                )
                let color = rl.Color(
                    r = unsafe: read(mesh.colors + ptr_uint<-(index * 4 + 0)),
                    g = unsafe: read(mesh.colors + ptr_uint<-(index * 4 + 1)),
                    b = unsafe: read(mesh.colors + ptr_uint<-(index * 4 + 2)),
                    a = unsafe: read(mesh.colors + ptr_uint<-(index * 4 + 3))
                )
                rl.draw_point_3d(pos, color)
                index += 1
        rl.draw_sphere_wires(position, 1.0, 10, 10, rl.YELLOW)
        rl.end_mode_3d()

        rl.draw_text(point_count_text, 10, SCREEN_HEIGHT - 50, 40, rl.WHITE)
        rl.draw_text("UP - Increase points", 10, 40, 20, rl.WHITE)
        rl.draw_text("DOWN - Decrease points", 10, 70, 20, rl.WHITE)
        rl.draw_text("SPACE - Drawing function", 10, 100, 20, rl.WHITE)
        rl.draw_text(draw_mode_text, 10, 130, 20, draw_mode_color)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
