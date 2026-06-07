import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const NUM_MODELS: int = 9


function gen_mesh_custom() -> rl.Mesh:
    var vertices = array[float, 9](
        0.0, 0.0, 0.0,
        1.0, 0.0, 2.0,
        2.0, 0.0, 0.0
    )
    var texcoords = array[float, 6](
        0.0, 0.0,
        0.5, 1.0,
        1.0, 0.0
    )
    var normals = array[float, 9](
        0.0, 1.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 1.0, 0.0
    )

    var mesh = rl.Mesh(
        triangleCount = 1,
        vertexCount = 3,
        vertices = unsafe: ptr[float]<-ptr_of(vertices[0]),
        texcoords = unsafe: ptr[float]<-ptr_of(texcoords[0]),
        texcoords2 = zero[ptr[float]],
        normals = unsafe: ptr[float]<-ptr_of(normals[0]),
        tangents = zero[ptr[float]],
        colors = zero[ptr[ubyte]],
        indices = null,
        boneCount = 0,
        boneIndices = zero[ptr[ubyte]],
        boneWeights = zero[ptr[float]],
        animVertices = zero[ptr[float]],
        animNormals = zero[ptr[float]],
        vaoId = 0,
        vboId = zero[ptr[uint]]
    )

    rl.upload_mesh(ptr_of(mesh), false)
    return mesh


function model_name(index: int) -> str:
    let names = array[str, NUM_MODELS](
        "PLANE",
        "CUBE",
        "SPHERE",
        "HEMISPHERE",
        "CYLINDER",
        "TORUS",
        "KNOT",
        "POLY",
        "Custom (triangle)"
    )
    return names[index]


function model_name_x(index: int) -> int:
    if index == 3:
        return 640
    if index == 8:
        return 580
    return 680


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - mesh generation")
    defer rl.close_window()

    let checked = rl.gen_image_checked(2, 2, 1, 1, rl.RED, rl.GREEN)
    defer rl.unload_image(checked)
    let texture = rl.load_texture_from_image(checked)
    defer rl.unload_texture(texture)

    var models: array[rl.Model, NUM_MODELS] = zero[array[rl.Model, NUM_MODELS]]
    models[0] = rl.load_model_from_mesh(rl.gen_mesh_plane(2.0, 2.0, 4, 3))
    models[1] = rl.load_model_from_mesh(rl.gen_mesh_cube(2.0, 1.0, 2.0))
    models[2] = rl.load_model_from_mesh(rl.gen_mesh_sphere(2.0, 32, 32))
    models[3] = rl.load_model_from_mesh(rl.gen_mesh_hemi_sphere(2.0, 16, 16))
    models[4] = rl.load_model_from_mesh(rl.gen_mesh_cylinder(1.0, 2.0, 16))
    models[5] = rl.load_model_from_mesh(rl.gen_mesh_torus(0.25, 4.0, 16, 32))
    models[6] = rl.load_model_from_mesh(rl.gen_mesh_knot(1.0, 2.0, 16, 128))
    models[7] = rl.load_model_from_mesh(rl.gen_mesh_poly(5, 2.0))
    models[8] = rl.load_model_from_mesh(gen_mesh_custom())

    var index = 0
    while index < NUM_MODELS:
        rl.set_material_texture(models[index].materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)
        index += 1

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 5.0, y = 5.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )
    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    var current_model = 0

    defer:
        index = 0
        while index < NUM_MODELS:
            rl.unload_model(models[index])
            index += 1

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            current_model = (current_model + 1) % NUM_MODELS

        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            current_model += 1
            if current_model >= NUM_MODELS:
                current_model = 0
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            current_model -= 1
            if current_model < 0:
                current_model = NUM_MODELS - 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_model(models[current_model], position, 1.0, rl.WHITE)
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        rl.draw_rectangle(30, 400, 310, 30, rl.fade(rl.SKYBLUE, 0.5))
        rl.draw_rectangle_lines(30, 400, 310, 30, rl.fade(rl.DARKBLUE, 0.5))
        rl.draw_text("MOUSE LEFT BUTTON to CYCLE PROCEDURAL MODELS", 40, 410, 10, rl.BLUE)
        rl.draw_text(model_name(current_model), model_name_x(current_model), 10, 20, rl.DARKBLUE)

        rl.end_drawing()

    return 0
