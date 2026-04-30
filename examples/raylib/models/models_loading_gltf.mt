module examples.raylib.models.models_loading_gltf

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [models] example - loading gltf"
const model_path: cstr = c"../resources/models/gltf/robot.glb"
const current_animation_format: cstr = c"Current animation: %s"
const controls_text: cstr = c"Use the LEFT/RIGHT keys to switch animation"

def chars_to_cstr(text: ptr[char]) -> cstr:
    unsafe:
        return cstr<-text

def model_animation(anims: ptr[rl.ModelAnimation], index: i32) -> rl.ModelAnimation:
    unsafe:
        return deref(anims + index)

def model_animation_name(anims: ptr[rl.ModelAnimation], index: i32) -> cstr:
    unsafe:
        return chars_to_cstr(raw(addr(deref(anims + index).name[0])))

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

    var anim_index = 0
    var anim_current_frame: f32 = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(raw(addr(camera)), rl.CameraMode.CAMERA_ORBITAL)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            anim_index = (anim_index + 1) % anim_count
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
            anim_index = (anim_index + anim_count - 1) % anim_count

        let anim = model_animation(anims, anim_index)
        anim_current_frame += 1.0
        rl.UpdateModelAnimation(model, anim, anim_current_frame)
        if anim_current_frame >= f32<-anim.keyframeCount:
            anim_current_frame = 0.0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)
        rl.DrawModel(model, position, 1.0, rl.WHITE)
        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()

        rl.DrawText(rl.TextFormat(current_animation_format, model_animation_name(anims, anim_index)), 10, 40, 20, rl.MAROON)
        rl.DrawText(controls_text, 10, 10, 20, rl.GRAY)

    return 0
