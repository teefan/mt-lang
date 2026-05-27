import std.raygui as gui
import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_ANIMATION_NAMES: int = 64


function animation_name(animations: ptr[rl.ModelAnimation], index: int) -> str:
    var anim = unsafe: animations[index]
    return text.chars_as_str(ptr_of(anim.name[0]))


function joined_animation_names(animations: ptr[rl.ModelAnimation], count: int) -> str:
    if count > MAX_ANIMATION_NAMES:
        fatal("animation count exceeds joined name buffer")

    var names: array[ptr[char], MAX_ANIMATION_NAMES] = zero[array[ptr[char], MAX_ANIMATION_NAMES]]
    var index = 0
    while index < count:
        var anim = unsafe: animations[index]
        names[index] = ptr_of(anim.name[0])
        index += 1

    return text.chars_as_str(rl.text_join(ptr_of(names[0]), count, ";"))


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - animation timing")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 6.0, y = 6.0, z = 6.0),
        target = rl.Vector3(x = 0.0, y = 2.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let model = rl.load_model("models/gltf/robot.glb")
    defer rl.unload_model(model)
    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    var anim_count = 0
    let animations = rl.load_model_animations("models/gltf/robot.glb", ptr_of(anim_count)) else:
        fatal("could not load gltf animations")
    defer rl.unload_model_animations(animations, anim_count)

    if anim_count == 0:
        fatal("robot.glb contains no animations")

    let animation_names_text = joined_animation_names(animations, anim_count)

    var anim_index = 0
    if anim_count > 10:
        anim_index = 10
    var anim_current_frame = float<-0.0
    var anim_frame_speed = float<-0.5
    var anim_pause = false
    var dropdown_edit_mode = false
    var anim_frame_progress = float<-0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_P):
            anim_pause = not anim_pause

        var current_animation = unsafe: animations[anim_index]
        if not anim_pause:
            anim_current_frame += anim_frame_speed
            if anim_current_frame >= float<-current_animation.keyframeCount:
                anim_current_frame = 0.0
            rl.update_model_animation(model, current_animation, anim_current_frame)

        anim_frame_progress = anim_current_frame
        let frame_speed_text = text.cstr_as_str(rl.text_format("x%.1f", anim_frame_speed))
        let timeline_text = rl.text_format("CURRENT FRAME: %.2f / %i", anim_frame_progress, current_animation.keyframeCount)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_model(model, position, 1.0, rl.WHITE)
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        gui.set_style(gui.Control.DROPDOWNBOX, int<-gui.DropdownBoxProperty.DROPDOWN_ITEMS_SPACING, 1)
        if gui.dropdown_box(rl.Rectangle(x = 10.0, y = 10.0, width = 140.0, height = 24.0), animation_names_text, anim_index, dropdown_edit_mode) != 0:
            dropdown_edit_mode = not dropdown_edit_mode

        gui.slider(rl.Rectangle(x = 260.0, y = 10.0, width = 500.0, height = 24.0), "FRAME SPEED: ", frame_speed_text, anim_frame_speed, 0.1, 2.0)
        gui.label(rl.Rectangle(x = 10.0, y = float<-rl.get_screen_height() - 64.0, width = float<-rl.get_screen_width() - 20.0, height = 24.0), timeline_text)
        gui.progress_bar(
            rl.Rectangle(x = 10.0, y = float<-rl.get_screen_height() - 40.0, width = float<-rl.get_screen_width() - 20.0, height = 24.0),
            "",
            "",
            anim_frame_progress,
            0.0,
            float<-current_animation.keyframeCount,
        )

        var index = 0
        while index < current_animation.keyframeCount:
            let keyframe_x = 10 + int<-((float<-(rl.get_screen_width() - 20) / float<-current_animation.keyframeCount) * float<-index)
            rl.draw_rectangle(keyframe_x, rl.get_screen_height() - 40, 1, 24, rl.BLUE)
            index += 1

        rl.end_drawing()

    return 0
