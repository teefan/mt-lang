module examples.raylib.models.models_animation_blending

import std.c.raygui as gui
import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const max_anim_names: i32 = 64
const empty_text: cstr = c""
const transition_text: cstr = c"ANIM TRANSITION BLENDING!"
const shader_vertex_path_format: cstr = c"../resources/shaders/glsl%i/skinning.vs"
const shader_fragment_path_format: cstr = c"../resources/shaders/glsl%i/skinning.fs"
const model_path: cstr = c"../resources/models/gltf/robot.glb"
const anim0_label: cstr = c"ANIM 0"
const anim1_label: cstr = c"ANIM 1"
const frame0_format: cstr = c"FRAME: %.2f / %i"
const frame1_format: cstr = c"FRAME: %.2f / %i"
const left_speed_format: cstr = c"x%.1f"
const right_speed_format: cstr = c"%.1fx"
const window_title: cstr = c"raylib [models] example - animation blending"


def chars_to_cstr(text: ptr[char]) -> cstr:
    unsafe:
        return cstr<-text


def model_animation(anims: ptr[rl.ModelAnimation], index: i32) -> rl.ModelAnimation:
    unsafe:
        return read(anims + index)


def model_animation_name(anims: ptr[rl.ModelAnimation], index: i32) -> cstr:
    unsafe:
        return chars_to_cstr(ptr_of((anims + index).name[0]))


def text_join(text_list: ptr[cstr], count: i32, delimiter: cstr) -> cstr:
    unsafe:
        return cstr<-rl.TextJoin(ptr[ptr[char]]<-text_list, count, delimiter)


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 6.0, y = 6.0, z = 6.0),
        target = rl.Vector3(x = 0.0, y = 2.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let model = rl.LoadModel(model_path)
    defer rl.UnloadModel(model)
    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    let skinning_shader = rl.LoadShader(
        rl.TextFormat(shader_vertex_path_format, glsl_version),
        rl.TextFormat(shader_fragment_path_format, glsl_version),
    )
    defer rl.UnloadShader(skinning_shader)

    var anim_count = 0
    let anims = rl.LoadModelAnimations(model_path, ptr_of(anim_count))
    defer rl.UnloadModelAnimations(anims, anim_count)

    var current_anim_playing = 0
    var next_anim_to_play = 1
    var anim_transition = false

    var anim_index0 = 10
    var anim_current_frame0: f32 = 0.0
    var anim_frame_speed0: f32 = 0.5
    var anim_index1 = 6
    var anim_current_frame1: f32 = 0.0
    var anim_frame_speed1: f32 = 0.5

    var anim_blend_factor: f32 = 0.0
    let anim_blend_time: f32 = 2.0
    var anim_blend_time_counter: f32 = 0.0
    var anim_pause = false

    var anim_names = zero[array[cstr, max_anim_names]]()
    for index in 0..anim_count:
        anim_names[index] = model_animation_name(anims, index)

    var dropdown_edit_mode0 = false
    var dropdown_edit_mode1 = false
    var anim_frame_progress0: f32 = 0.0
    var anim_frame_progress1: f32 = 0.0
    var anim_blend_progress: f32 = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(camera), rl.CameraMode.CAMERA_ORBITAL)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_P):
            anim_pause = not anim_pause

        if not anim_pause:
            if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE) and not anim_transition:
                if current_anim_playing == 0:
                    next_anim_to_play = 1
                    anim_current_frame1 = 0.0
                else:
                    next_anim_to_play = 0
                    anim_current_frame0 = 0.0

                anim_transition = true
                anim_blend_time_counter = 0.0
                anim_blend_factor = 0.0

            if anim_transition:
                let anim0 = model_animation(anims, anim_index0)
                let anim1 = model_animation(anims, anim_index1)

                anim_current_frame0 += anim_frame_speed0
                if anim_current_frame0 >= f32<-anim0.keyframeCount:
                    anim_current_frame0 = 0.0

                anim_current_frame1 += anim_frame_speed1
                if anim_current_frame1 >= f32<-anim1.keyframeCount:
                    anim_current_frame1 = 0.0

                anim_blend_factor = anim_blend_time_counter / anim_blend_time
                anim_blend_time_counter += rl.GetFrameTime()
                anim_blend_progress = anim_blend_factor

                if next_anim_to_play == 1:
                    rl.UpdateModelAnimationEx(model, anim0, anim_current_frame0, anim1, anim_current_frame1, anim_blend_factor)
                else:
                    rl.UpdateModelAnimationEx(model, anim1, anim_current_frame1, anim0, anim_current_frame0, anim_blend_factor)

                if anim_blend_factor > 1.0:
                    if current_anim_playing == 0:
                        anim_current_frame0 = 0.0
                    elif current_anim_playing == 1:
                        anim_current_frame1 = 0.0

                    current_anim_playing = next_anim_to_play
                    anim_blend_factor = 0.0
                    anim_transition = false
                    anim_blend_time_counter = 0.0
            else:
                if current_anim_playing == 0:
                    let anim0 = model_animation(anims, anim_index0)
                    anim_current_frame0 += anim_frame_speed0
                    if anim_current_frame0 >= f32<-anim0.keyframeCount:
                        anim_current_frame0 = 0.0
                    rl.UpdateModelAnimation(model, anim0, anim_current_frame0)
                elif current_anim_playing == 1:
                    let anim1 = model_animation(anims, anim_index1)
                    anim_current_frame1 += anim_frame_speed1
                    if anim_current_frame1 >= f32<-anim1.keyframeCount:
                        anim_current_frame1 = 0.0
                    rl.UpdateModelAnimation(model, anim1, anim_current_frame1)

        anim_frame_progress0 = anim_current_frame0
        anim_frame_progress1 = anim_current_frame1

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)
        rl.DrawModel(model, position, 1.0, rl.WHITE)
        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()

        if anim_transition:
            rl.DrawText(transition_text, 170, 50, 30, rl.BLUE)

        if dropdown_edit_mode0:
            gui.GuiDisable()
        gui.GuiSlider(
            gui.Rectangle(x = 10.0, y = 38.0, width = 160.0, height = 12.0),
            empty_text,
            rl.TextFormat(left_speed_format, anim_frame_speed0),
            ptr_of(anim_frame_speed0),
            0.1,
            2.0,
        )
        gui.GuiEnable()

        if dropdown_edit_mode1:
            gui.GuiDisable()
        gui.GuiSlider(
            gui.Rectangle(x = rl.GetScreenWidth() - 170.0, y = 38.0, width = 160.0, height = 12.0),
            rl.TextFormat(right_speed_format, anim_frame_speed1),
            empty_text,
            ptr_of(anim_frame_speed1),
            0.1,
            2.0,
        )
        gui.GuiEnable()

        gui.GuiSetStyle(gui.GuiControl.DROPDOWNBOX, i32<-gui.GuiDropdownBoxProperty.DROPDOWN_ITEMS_SPACING, 1)
        if gui.GuiDropdownBox(
            gui.Rectangle(x = 10.0, y = 10.0, width = 160.0, height = 24.0),
            text_join(ptr_of(anim_names[0]), anim_count, c";"),
            ptr_of(anim_index0),
            dropdown_edit_mode0,
        ) != 0:
            dropdown_edit_mode0 = not dropdown_edit_mode0

        if next_anim_to_play == 1:
            gui.GuiSetStyle(gui.GuiControl.PROGRESSBAR, i32<-gui.GuiProgressBarProperty.PROGRESS_SIDE, 0)
        else:
            gui.GuiSetStyle(gui.GuiControl.PROGRESSBAR, i32<-gui.GuiProgressBarProperty.PROGRESS_SIDE, 1)

        gui.GuiProgressBar(
            gui.Rectangle(x = 180.0, y = 14.0, width = 440.0, height = 16.0),
            empty_text,
            empty_text,
            ptr_of(anim_blend_progress),
            0.0,
            1.0,
        )
        gui.GuiSetStyle(gui.GuiControl.PROGRESSBAR, i32<-gui.GuiProgressBarProperty.PROGRESS_SIDE, 0)

        if gui.GuiDropdownBox(
            gui.Rectangle(x = rl.GetScreenWidth() - 170.0, y = 10.0, width = 160.0, height = 24.0),
            text_join(ptr_of(anim_names[0]), anim_count, c";"),
            ptr_of(anim_index1),
            dropdown_edit_mode1,
        ) != 0:
            dropdown_edit_mode1 = not dropdown_edit_mode1

        let anim0 = model_animation(anims, anim_index0)
        gui.GuiProgressBar(
            gui.Rectangle(x = 60.0, y = rl.GetScreenHeight() - 60.0, width = rl.GetScreenWidth() - 180.0, height = 20.0),
            anim0_label,
            rl.TextFormat(frame0_format, anim_frame_progress0, anim0.keyframeCount),
            ptr_of(anim_frame_progress0),
            0.0,
            f32<-anim0.keyframeCount,
        )
        for index in 0..anim0.keyframeCount:
            let timeline_x = 60 + i32<-((f32<-(rl.GetScreenWidth() - 180) / f32<-anim0.keyframeCount) * f32<-index)
            rl.DrawRectangle(timeline_x, rl.GetScreenHeight() - 60, 1, 20, rl.BLUE)

        let anim1 = model_animation(anims, anim_index1)
        gui.GuiProgressBar(
            gui.Rectangle(x = 60.0, y = rl.GetScreenHeight() - 30.0, width = rl.GetScreenWidth() - 180.0, height = 20.0),
            anim1_label,
            rl.TextFormat(frame1_format, anim_frame_progress1, anim1.keyframeCount),
            ptr_of(anim_frame_progress1),
            0.0,
            f32<-anim1.keyframeCount,
        )
        for index in 0..anim1.keyframeCount:
            let timeline_x = 60 + i32<-((f32<-(rl.GetScreenWidth() - 180) / f32<-anim1.keyframeCount) * f32<-index)
            rl.DrawRectangle(timeline_x, rl.GetScreenHeight() - 30, 1, 20, rl.BLUE)

    return 0
