import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - texture tiling")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 4.0, y = 4.0, z = 4.0),
        target = rl.Vector3(x = 0.0, y = 0.5, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let cube = rl.gen_mesh_cube(1.0, 1.0, 1.0)
    var model = rl.load_model_from_mesh(cube)
    defer rl.unload_model(model)

    let texture = rl.load_texture("cubicmap_atlas.png")
    defer rl.unload_texture(texture)
    rl.set_material_texture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    let tiling = rl.Vector2(x = 3.0, y = 3.0)
    let shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/tiling.fs", GLSL_VERSION))
    defer rl.unload_shader(shader)
    rl.set_texture_wrap(texture, int<-rl.TextureWrap.TEXTURE_WRAP_REPEAT)
    rl.set_shader_value(shader, rl.get_shader_location(shader, "tiling"), tiling, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
    unsafe: model.materials[0].shader = shader

    rl.disable_cursor()
    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_FREE)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_Z):
            camera.target = rl.Vector3(x = 0.0, y = 0.5, z = 0.0)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.begin_shader_mode(shader)
        rl.draw_model(model, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 2.0, rl.WHITE)
        rl.end_shader_mode()
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        rl.draw_text("Use mouse to rotate the camera", 10, 10, 20, rl.DARKGRAY)
        rl.end_drawing()

    return 0
