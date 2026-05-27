import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function animation_name(animations: ptr[rl.ModelAnimation], index: int) -> str:
    var anim = unsafe: animations[index]
    return text.chars_as_str(ptr_of(anim.name[0]))


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - animation gpu skinning")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 5.0, y = 5.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var model = rl.load_model("models/gltf/greenman.glb")
    defer rl.unload_model(model)
    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    let skinning_vertex_shader = rl.text_format("shaders/glsl%i/skinning.vs", GLSL_VERSION)
    let skinning_fragment_shader = rl.text_format("shaders/glsl%i/skinning.fs", GLSL_VERSION)
    let skinning_shader = rl.load_shader(skinning_vertex_shader, skinning_fragment_shader)
    defer rl.unload_shader(skinning_shader)
    unsafe: model.materials[1].shader = skinning_shader

    var anim_count = 0
    let animations = rl.load_model_animations("models/gltf/greenman.glb", ptr_of(anim_count)) else:
        fatal("could not load greenman animations")
    defer rl.unload_model_animations(animations, anim_count)

    var anim_index = 0
    var anim_current_frame = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            anim_index = (anim_index + 1) % anim_count
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            anim_index = (anim_index + anim_count - 1) % anim_count

        var animation = unsafe: animations[anim_index]
        anim_current_frame = (anim_current_frame + 1) % animation.keyframeCount
        rl.update_model_animation(model, animation, float<-anim_current_frame)

        let current_animation_name = animation_name(animations, anim_index)
        let current_animation_text = rl.text_format("Current animation: %s", current_animation_name)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_model(model, position, 1.0, rl.WHITE)
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        rl.draw_text("Use the LEFT/RIGHT keys to switch animation", 10, 10, 20, rl.GRAY)
        rl.draw_text(current_animation_text, 10, 40, 20, rl.MAROON)
        rl.end_drawing()

    return 0
