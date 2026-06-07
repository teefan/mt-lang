import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - custom uniform")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 8.0, y = 8.0, z = 8.0),
        target = rl.Vector3(x = 0.0, y = 1.5, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    let model = rl.load_model("models/barracks.obj")
    defer rl.unload_model(model)
    let texture = rl.load_texture("models/barracks_diffuse.png")
    defer rl.unload_texture(texture)
    rl.set_material_texture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    let shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/swirl.fs", GLSL_VERSION))
    defer rl.unload_shader(shader)
    let swirl_center_location = rl.get_shader_location(shader, "center")

    let target = rl.load_render_texture(SCREEN_WIDTH, SCREEN_HEIGHT)
    defer rl.unload_render_texture(target)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        let mouse_position = rl.get_mouse_position()
        let swirl_center = rl.Vector2(
            x = mouse_position.x,
            y = float<-SCREEN_HEIGHT - mouse_position.y
        )
        rl.set_shader_value(
            shader,
            swirl_center_location,
            swirl_center,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2
        )

        rl.begin_texture_mode(target)
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_model(model, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 0.5, rl.WHITE)
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        rl.draw_text("TEXT DRAWN IN RENDER TEXTURE", 200, 10, 30, rl.RED)
        rl.end_texture_mode()

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_shader_mode(shader)
        rl.draw_texture_rec(
            target.texture,
            rl.Rectangle(
                x = 0.0,
                y = 0.0,
                width = float<-target.texture.width,
                height = -(float<-target.texture.height)
            ),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE
        )
        rl.end_shader_mode()

        rl.draw_text("(c) Barracks 3D model by Alberto Cano", SCREEN_WIDTH - 220, SCREEN_HEIGHT - 20, 10, rl.GRAY)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
