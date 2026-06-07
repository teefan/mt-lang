import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as rm

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - simple mask")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 0.0, y = 1.0, z = 2.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    let torus = rl.gen_mesh_torus(0.3, 1.0, 16, 32)
    var model1 = rl.load_model_from_mesh(torus)
    defer rl.unload_model(model1)

    let cube = rl.gen_mesh_cube(0.8, 0.8, 0.8)
    var model2 = rl.load_model_from_mesh(cube)
    defer rl.unload_model(model2)

    let sphere = rl.gen_mesh_sphere(1.0, 16, 16)
    let model3 = rl.load_model_from_mesh(sphere)
    defer rl.unload_model(model3)

    var shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/mask.fs", GLSL_VERSION))
    defer rl.unload_shader(shader)

    let diffuse = rl.load_texture("plasma.png")
    defer rl.unload_texture(diffuse)
    rl.set_material_texture(model1.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, diffuse)
    rl.set_material_texture(model2.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, diffuse)

    let mask = rl.load_texture("mask.png")
    defer rl.unload_texture(mask)
    rl.set_material_texture(model1.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_EMISSION, mask)
    rl.set_material_texture(model2.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_EMISSION, mask)

    unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_MAP_EMISSION] = rl.get_shader_location(shader, "mask")
    let frame_location = rl.get_shader_location(shader, "frame")

    unsafe: model1.materials[0].shader = shader
    unsafe: model2.materials[0].shader = shader

    var frame_counter = 0
    var rotation = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    rl.disable_cursor()
    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_FIRST_PERSON)

        frame_counter += 1
        rotation.x += 0.01
        rotation.y += 0.005
        rotation.z -= 0.0025

        rl.set_shader_value(shader, frame_location, frame_counter, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT)
        model1.transform = rm.matrix_rotate_xyz(rotation)

        rl.begin_drawing()
        rl.clear_background(rl.DARKBLUE)

        rl.begin_mode_3d(camera)
        rl.draw_model(model1, rl.Vector3(x = 0.5, y = 0.0, z = 0.0), 1.0, rl.WHITE)
        rl.draw_model_ex(
            model2,
            rl.Vector3(x = -0.5, y = 0.0, z = 0.0),
            rl.Vector3(x = 1.0, y = 1.0, z = 0.0),
            50.0,
            rl.Vector3(x = 1.0, y = 1.0, z = 1.0),
            rl.WHITE
        )
        rl.draw_model(model3, rl.Vector3(x = 0.0, y = 0.0, z = -1.5), 1.0, rl.WHITE)
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        let frame_text = rl.text_format("Frame: %i", frame_counter)
        let frame_width = rl.measure_text(frame_text, 20)
        rl.draw_rectangle(16, SCREEN_HEIGHT - 42, frame_width + 8, 42, rl.BLUE)
        rl.draw_text(frame_text, 20, SCREEN_HEIGHT - 40, 20, rl.WHITE)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
