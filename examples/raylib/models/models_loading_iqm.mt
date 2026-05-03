module examples.raylib.models.models_loading_iqm

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [models] example - loading iqm"
const model_path: cstr = c"../resources/models/iqm/guy.iqm"
const texture_path: cstr = c"../resources/models/iqm/guytex.png"
const animation_path: cstr = c"../resources/models/iqm/guyanim.iqm"
const current_animation_format: cstr = c"Current animation: %s"
const credit_text: cstr = c"(c) Guy IQM 3D model by @culacant"


def chars_to_cstr(text: ptr[char]) -> cstr:
    unsafe:
        return cstr<-text


def model_animation(anims: ptr[rl.ModelAnimation], index: i32) -> rl.ModelAnimation:
    unsafe:
        return read(anims + index)


def model_animation_name(anims: ptr[rl.ModelAnimation], index: i32) -> cstr:
    unsafe:
        return chars_to_cstr(ptr_of(ref_of((anims + index).name[0])))


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 10.0, y = 10.0, z = 10.0),
        target = rl.Vector3(x = 0.0, y = 4.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let model = rl.LoadModel(model_path)
    defer rl.UnloadModel(model)

    let texture = rl.LoadTexture(texture_path)
    defer rl.UnloadTexture(texture)

    rl.SetMaterialTexture(model.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    var anim_count = 0
    let anims = rl.LoadModelAnimations(animation_path, ptr_of(ref_of(anim_count)))
    defer rl.UnloadModelAnimations(anims, anim_count)

    let anim_index = 0
    var anim_current_frame: f32 = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(ref_of(camera)), rl.CameraMode.CAMERA_ORBITAL)

        let anim = model_animation(anims, anim_index)
        anim_current_frame += 1.0
        rl.UpdateModelAnimation(model, anim, anim_current_frame)
        if anim_current_frame >= f32<-anim.keyframeCount:
            anim_current_frame = 0.0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode3D(camera)
        rl.DrawModelEx(
            model,
            position,
            rl.Vector3(x = 1.0, y = 0.0, z = 0.0),
            -90.0,
            rl.Vector3(x = 1.0, y = 1.0, z = 1.0),
            rl.WHITE,
        )
        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()

        rl.DrawText(rl.TextFormat(current_animation_format, model_animation_name(anims, anim_index)), 10, 10, 20, rl.MAROON)
        rl.DrawText(credit_text, screen_width - 200, screen_height - 20, 10, rl.GRAY)

    return 0
