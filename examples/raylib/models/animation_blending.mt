import std.raygui as gui
import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_ANIMATION_NAMES: int = 64
const GLSL_VERSION: int = 330


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
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - animation blending")
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

    let skinning_vertex_shader = rl.text_format("shaders/glsl%i/skinning.vs", GLSL_VERSION)
    let skinning_fragment_shader = rl.text_format("shaders/glsl%i/skinning.fs", GLSL_VERSION)
    let skinning_shader = rl.load_shader(skinning_vertex_shader, skinning_fragment_shader)
    defer rl.unload_shader(skinning_shader)

    var anim_count = 0
    let animations = rl.load_model_animations("models/gltf/robot.glb", ptr_of(anim_count)) else:
        fatal("could not load robot animations")
    defer rl.unload_model_animations(animations, anim_count)

    let animation_names = joined_animation_names(animations, anim_count)

    var current_anim_playing = 0
    var next_anim_to_play = 1
    var anim_transition = false

    var anim_index0 = 0
    if anim_count > 10:
        anim_index0 = 10
    var anim_current_frame0 = float<-0.0
    var anim_frame_speed0 = float<-0.5
    var anim_index1 = 0
    if anim_count > 6:
        anim_index1 = 6
    else if anim_count > 1:
        anim_index1 = 1
    var anim_current_frame1 = float<-0.0
    var anim_frame_speed1 = float<-0.5

    var anim_blend_factor = float<-0.0
    let anim_blend_time = float<-2.0
    var anim_blend_time_counter = float<-0.0

    var anim_pause = false
    var dropdown_edit_mode0 = false
    var dropdown_edit_mode1 = false
    var anim_frame_progress0 = float<-0.0
    var anim_frame_progress1 = float<-0.0
    var anim_blend_progress = float<-0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_P):
            anim_pause = not anim_pause

        if not anim_pause:
            if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE) and not anim_transition:
                if current_anim_playing == 0:
                    next_anim_to_play = 1
                    anim_current_frame1 = 0.0
                else:
                    next_anim_to_play = 0
                    anim_current_frame0 = 0.0

                anim_transition = true
                anim_blend_time_counter = 0.0
                anim_blend_factor = 0.0

            var anim0 = unsafe: animations[anim_index0]
            var anim1 = unsafe: animations[anim_index1]

            if anim_transition:
                anim_current_frame0 += anim_frame_speed0
                if anim_current_frame0 >= float<-anim0.keyframeCount:
                    anim_current_frame0 = 0.0
                anim_current_frame1 += anim_frame_speed1
                if anim_current_frame1 >= float<-anim1.keyframeCount:
                    anim_current_frame1 = 0.0

                anim_blend_factor = anim_blend_time_counter / anim_blend_time
                anim_blend_time_counter += rl.get_frame_time()
                anim_blend_progress = anim_blend_factor

                if next_anim_to_play == 1:
                    rl.update_model_animation_ex(model, anim0, anim_current_frame0, anim1, anim_current_frame1, anim_blend_factor)
                else:
                    rl.update_model_animation_ex(model, anim1, anim_current_frame1, anim0, anim_current_frame0, anim_blend_factor)

                if anim_blend_factor > 1.0:
                    if current_anim_playing == 0:
                        anim_current_frame0 = 0.0
                    else if current_anim_playing == 1:
                        anim_current_frame1 = 0.0
                    current_anim_playing = next_anim_to_play
                    anim_blend_factor = 0.0
                    anim_transition = false
                    anim_blend_time_counter = 0.0

            else:
                if current_anim_playing == 0:
                    anim_current_frame0 += anim_frame_speed0
                    if anim_current_frame0 >= float<-anim0.keyframeCount:
                        anim_current_frame0 = 0.0
                    rl.update_model_animation(model, anim0, anim_current_frame0)
                else if current_anim_playing == 1:
                    anim_current_frame1 += anim_frame_speed1
                    if anim_current_frame1 >= float<-anim1.keyframeCount:
                        anim_current_frame1 = 0.0
                    rl.update_model_animation(model, anim1, anim_current_frame1)

        anim_frame_progress0 = anim_current_frame0
        anim_frame_progress1 = anim_current_frame1

        var anim0 = unsafe: animations[anim_index0]
        var anim1 = unsafe: animations[anim_index1]
        let frame_speed_text0 = text.cstr_as_str(rl.text_format("x%.1f", anim_frame_speed0))
        let frame_speed_text1 = text.cstr_as_str(rl.text_format("%.1fx", anim_frame_speed1))
        let timeline_text0 = rl.text_format("FRAME: %.2f / %i", anim_frame_progress0, anim0.keyframeCount)
        let timeline_text1 = rl.text_format("FRAME: %.2f / %i", anim_frame_progress1, anim1.keyframeCount)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_model(model, position, 1.0, rl.WHITE)
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        if anim_transition:
            rl.draw_text("ANIM TRANSITION BLENDING!", 170, 50, 30, rl.BLUE)

        if dropdown_edit_mode0:
            gui.disable()
        gui.slider(rl.Rectangle(x = 10.0, y = 38.0, width = 160.0, height = 12.0), "", frame_speed_text0, anim_frame_speed0, 0.1, 2.0)
        gui.enable()

        if dropdown_edit_mode1:
            gui.disable()
        gui.slider(rl.Rectangle(x = float<-rl.get_screen_width() - 170.0, y = 38.0, width = 160.0, height = 12.0), frame_speed_text1, "", anim_frame_speed1, 0.1, 2.0)
        gui.enable()

        gui.set_style(gui.Control.DROPDOWNBOX, int<-gui.DropdownBoxProperty.DROPDOWN_ITEMS_SPACING, 1)
        if gui.dropdown_box(rl.Rectangle(x = 10.0, y = 10.0, width = 160.0, height = 24.0), animation_names, anim_index0, dropdown_edit_mode0) != 0:
            dropdown_edit_mode0 = not dropdown_edit_mode0

        if next_anim_to_play == 1:
            gui.set_style(gui.Control.PROGRESSBAR, int<-gui.ProgressBarProperty.PROGRESS_SIDE, 0)
        else:
            gui.set_style(gui.Control.PROGRESSBAR, int<-gui.ProgressBarProperty.PROGRESS_SIDE, 1)
        gui.progress_bar(rl.Rectangle(x = 180.0, y = 14.0, width = 440.0, height = 16.0), "", "", anim_blend_progress, 0.0, 1.0)
        gui.set_style(gui.Control.PROGRESSBAR, int<-gui.ProgressBarProperty.PROGRESS_SIDE, 0)

        if gui.dropdown_box(rl.Rectangle(x = float<-rl.get_screen_width() - 170.0, y = 10.0, width = 160.0, height = 24.0), animation_names, anim_index1, dropdown_edit_mode1) != 0:
            dropdown_edit_mode1 = not dropdown_edit_mode1

        gui.progress_bar(
            rl.Rectangle(x = 60.0, y = float<-rl.get_screen_height() - 60.0, width = float<-rl.get_screen_width() - 180.0, height = 20.0),
            "ANIM 0",
            timeline_text0,
            anim_frame_progress0,
            0.0,
            float<-anim0.keyframeCount,
        )
        var index = 0
        while index < anim0.keyframeCount:
            let keyframe_x = 60 + int<-((float<-(rl.get_screen_width() - 180) / float<-anim0.keyframeCount) * float<-index)
            rl.draw_rectangle(keyframe_x, rl.get_screen_height() - 60, 1, 20, rl.BLUE)
            index += 1

        gui.progress_bar(
            rl.Rectangle(x = 60.0, y = float<-rl.get_screen_height() - 30.0, width = float<-rl.get_screen_width() - 180.0, height = 20.0),
            "ANIM 1",
            timeline_text1,
            anim_frame_progress1,
            0.0,
            float<-anim1.keyframeCount,
        )
        index = 0
        while index < anim1.keyframeCount:
            let keyframe_x = 60 + int<-((float<-(rl.get_screen_width() - 180) / float<-anim1.keyframeCount) * float<-index)
            rl.draw_rectangle(keyframe_x, rl.get_screen_height() - 30, 1, 20, rl.BLUE)
            index += 1

        rl.end_drawing()

    return 0
