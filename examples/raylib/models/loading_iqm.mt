import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - loading iqm")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 10.0, y = 10.0, z = 10.0),
        target = rl.Vector3(x = 0.0, y = 4.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    let model = rl.load_model("models/iqm/guy.iqm")
    defer rl.unload_model(model)
    let texture = rl.load_texture("models/iqm/guytex.png")
    defer rl.unload_texture(texture)
    rl.set_material_texture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    var anim_count = 0
    let animations = rl.load_model_animations("models/iqm/guyanim.iqm", ptr_of(anim_count)) else:
        fatal("could not load iqm animations")
    defer rl.unload_model_animations(animations, anim_count)

    var anim_current_frame = float<-0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        anim_current_frame += 1.0
        var animation = unsafe: animations[0]
        rl.update_model_animation(model, animation, anim_current_frame)
        if anim_current_frame >= float<-animation.keyframeCount:
            anim_current_frame = 0.0

        let current_animation_name = text.chars_as_str(ptr_of(animation.name[0]))
        let current_animation_text = rl.text_format("Current animation: %s", current_animation_name)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_model_ex(
            model,
            position,
            rl.Vector3(x = 1.0, y = 0.0, z = 0.0),
            -90.0,
            rl.Vector3(x = 1.0, y = 1.0, z = 1.0),
            rl.WHITE,
        )
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        rl.draw_text(current_animation_text, 10, 10, 20, rl.MAROON)
        rl.draw_text("(c) Guy IQM 3D model by @culacant", SCREEN_WIDTH - 200, SCREEN_HEIGHT - 20, 10, rl.GRAY)
        rl.end_drawing()

    return 0
