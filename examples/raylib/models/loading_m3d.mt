import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function animation_name(animations: ptr[rl.ModelAnimation], index: int) -> str:
    var anim = unsafe: animations[index]
    return text.chars_as_str(ptr_of(anim.name[0]))


function draw_model_skeleton(skeleton: rl.ModelSkeleton, pose: rl.ModelAnimPose, scale: float, color: rl.Color) -> void:
    var index = 0
    while index < skeleton.boneCount - 1:
        let current_pose = unsafe: pose[index]
        rl.draw_cube(current_pose.translation, scale * 0.05, scale * 0.05, scale * 0.05, color)

        let bone = unsafe: skeleton.bones[index]
        if bone.parent >= 0:
            let parent_pose = unsafe: pose[bone.parent]
            rl.draw_line_3d(current_pose.translation, parent_pose.translation, color)

        index += 1


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - loading m3d")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 1.5, y = 1.5, z = 1.5),
        target = rl.Vector3(x = 0.0, y = 0.4, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let model = rl.load_model("models/m3d/cesium_man.m3d")
    defer rl.unload_model(model)
    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    var anim_count = 0
    let animations = rl.load_model_animations("models/m3d/cesium_man.m3d", ptr_of(anim_count)) else:
        fatal("could not load m3d animations")
    defer rl.unload_model_animations(animations, anim_count)

    var anim_index = 0
    var anim_current_frame = float<-0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            anim_index = (anim_index + 1) % anim_count
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            anim_index = (anim_index + anim_count - 1) % anim_count

        var animation = unsafe: animations[anim_index]
        anim_current_frame += 1.0
        if anim_current_frame >= float<-animation.keyframeCount:
            anim_current_frame = 0.0
        rl.update_model_animation(model, animation, anim_current_frame)

        let current_animation_text = rl.text_format("Current animation: %s", animation_name(animations, anim_index))
        let skeleton_pose = unsafe: animation.keyframePoses[int<-anim_current_frame]

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        if not rl.is_key_down(rl.KeyboardKey.KEY_SPACE):
            rl.draw_model(model, position, 1.0, rl.WHITE)
        else:
            draw_model_skeleton(model.skeleton, skeleton_pose, 1.0, rl.RED)
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        rl.draw_text(current_animation_text, 10, 10, 20, rl.LIGHTGRAY)
        rl.draw_text("Press SPACE to draw skeleton", 10, 40, 20, rl.MAROON)
        rl.draw_text("(c) CesiumMan model by KhronosGroup", rl.get_screen_width() - 210, rl.get_screen_height() - 20, 10, rl.GRAY)
        rl.end_drawing()

    return 0
