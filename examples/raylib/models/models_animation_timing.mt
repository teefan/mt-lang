module examples.raylib.models.models_animation_timing

import std.c.raygui as gui
import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const max_anim_names: i32 = 64
const empty_text: cstr = c""
const anim_speed_format: cstr = c"x%.1f"
const current_frame_format: cstr = c"CURRENT FRAME: %.2f / %i"
const frame_speed_label: cstr = c"FRAME SPEED: "
const model_path: cstr = c"../resources/models/gltf/robot.glb"
const window_title: cstr = c"raylib [models] example - animation timing"

def chars_to_cstr(text: ptr[char]) -> cstr:
    unsafe:
        return cstr<-text

def model_animation(anims: ptr[rl.ModelAnimation], index: i32) -> rl.ModelAnimation:
    unsafe:
        return deref(anims + index)

def model_animation_name(anims: ptr[rl.ModelAnimation], index: i32) -> cstr:
    unsafe:
        return chars_to_cstr(raw(addr((anims + index).name[0])))

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

    var anim_count = 0
    let anims = rl.LoadModelAnimations(model_path, raw(addr(anim_count)))
    defer rl.UnloadModelAnimations(anims, anim_count)

    var anim_index = 10
    var anim_current_frame: f32 = 0.0
    var anim_frame_speed: f32 = 0.5
    var anim_pause = false

    var anim_names = zero[array[cstr, max_anim_names]]()
    for index in range(0, anim_count):
        anim_names[index] = model_animation_name(anims, index)

    var dropdown_edit_mode = false
    var anim_frame_progress: f32 = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(raw(addr(camera)), rl.CameraMode.CAMERA_ORBITAL)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_P):
            anim_pause = not anim_pause

        if not anim_pause and anim_index < anim_count:
            let anim = model_animation(anims, anim_index)
            anim_current_frame += anim_frame_speed
            if anim_current_frame >= f32<-anim.keyframeCount:
                anim_current_frame = 0.0
            rl.UpdateModelAnimation(model, anim, anim_current_frame)

        anim_frame_progress = anim_current_frame

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)
        rl.DrawModel(model, position, 1.0, rl.WHITE)
        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()

        gui.GuiSetStyle(gui.GuiControl.DROPDOWNBOX, i32<-gui.GuiDropdownBoxProperty.DROPDOWN_ITEMS_SPACING, 1)
        if gui.GuiDropdownBox(
            gui.Rectangle(x = 10.0, y = 10.0, width = 140.0, height = 24.0),
            text_join(raw(addr(anim_names[0])), anim_count, c";"),
            raw(addr(anim_index)),
            dropdown_edit_mode,
        ) != 0:
            dropdown_edit_mode = not dropdown_edit_mode

        gui.GuiSlider(
            gui.Rectangle(x = 260.0, y = 10.0, width = 500.0, height = 24.0),
            frame_speed_label,
            rl.TextFormat(anim_speed_format, anim_frame_speed),
            raw(addr(anim_frame_speed)),
            0.1,
            2.0,
        )

        let anim = model_animation(anims, anim_index)
        gui.GuiLabel(
            gui.Rectangle(x = 10.0, y = rl.GetScreenHeight() - 64.0, width = rl.GetScreenWidth() - 20.0, height = 24.0),
            rl.TextFormat(current_frame_format, anim_frame_progress, anim.keyframeCount),
        )
        gui.GuiProgressBar(
            gui.Rectangle(x = 10.0, y = rl.GetScreenHeight() - 40.0, width = rl.GetScreenWidth() - 20.0, height = 24.0),
            empty_text,
            empty_text,
            raw(addr(anim_frame_progress)),
            0.0,
            f32<-anim.keyframeCount,
        )

        for index in range(0, anim.keyframeCount):
            let timeline_x = 10 + i32<-((f32<-(rl.GetScreenWidth() - 20) / f32<-anim.keyframeCount) * f32<-index)
            rl.DrawRectangle(timeline_x, rl.GetScreenHeight() - 40, 1, 24, rl.BLUE)

    return 0
