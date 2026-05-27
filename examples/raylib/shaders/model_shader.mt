import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - model shader")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 4.0, y = 4.0, z = 4.0),
        target = rl.Vector3(x = 0.0, y = 1.0, z = -1.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var model = rl.load_model("models/watermill.obj")
    defer rl.unload_model(model)
    let texture = rl.load_texture("models/watermill_diffuse.png")
    defer rl.unload_texture(texture)

    let shader_path = rl.text_format("shaders/glsl%i/grayscale.fs", GLSL_VERSION)
    let shader = rl.load_shader(null, shader_path)
    defer rl.unload_shader(shader)

    unsafe: model.materials[0].shader = shader
    rl.set_material_texture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    rl.disable_cursor()
    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_FREE)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_model(model, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 0.2, rl.WHITE)
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        rl.draw_text("(c) Watermill 3D model by Alberto Cano", SCREEN_WIDTH - 210, SCREEN_HEIGHT - 20, 10, rl.GRAY)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
