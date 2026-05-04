module examples.raylib.models.models_loading_m3d

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [models] example - loading m3d"
const model_path: cstr = c"../resources/models/m3d/cesium_man.m3d"
const current_animation_format: cstr = c"Current animation: %s"
const skeleton_text: cstr = c"Press SPACE to draw skeleton"
const credit_text: cstr = c"(c) CesiumMan model by KhronosGroup"


def chars_to_cstr(text: ptr[char]) -> cstr:
    unsafe:
        return cstr<-text


def model_animation(anims: ptr[rl.ModelAnimation], index: i32) -> rl.ModelAnimation:
    unsafe:
        return read(anims + index)


def model_animation_name(anims: ptr[rl.ModelAnimation], index: i32) -> cstr:
    unsafe:
        return chars_to_cstr(ptr_of((anims + index).name[0]))


def model_animation_pose(anim: rl.ModelAnimation, frame: i32) -> rl.ModelAnimPose:
    unsafe:
        return read(anim.keyframePoses + frame)


def pose_translation(pose: rl.ModelAnimPose, index: i32) -> rl.Vector3:
    unsafe:
        return (pose + index).translation


def skeleton_bone_parent(skeleton: rl.ModelSkeleton, index: i32) -> i32:
    unsafe:
        return (skeleton.bones + index).parent


def draw_model_skeleton(skeleton: rl.ModelSkeleton, pose: rl.ModelAnimPose, scale: f32, color: rl.Color) -> void:
    for index in 0..skeleton.boneCount - 1:
        let translation = pose_translation(pose, index)
        rl.DrawCube(translation, scale * 0.05, scale * 0.05, scale * 0.05, color)

        let parent = skeleton_bone_parent(skeleton, index)
        if parent >= 0:
            rl.DrawLine3D(translation, pose_translation(pose, parent), color)


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 1.5, y = 1.5, z = 1.5),
        target = rl.Vector3(x = 0.0, y = 0.4, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let model = rl.LoadModel(model_path)
    defer rl.UnloadModel(model)

    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    var anim_count = 0
    let anims = rl.LoadModelAnimations(model_path, ptr_of(anim_count))
    defer rl.UnloadModelAnimations(anims, anim_count)

    var anim_index = 0
    var anim_current_frame: f32 = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(camera), rl.CameraMode.CAMERA_ORBITAL)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            anim_index = (anim_index + 1) % anim_count
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
            anim_index = (anim_index + anim_count - 1) % anim_count

        let anim = model_animation(anims, anim_index)
        anim_current_frame += 1.0
        if anim_current_frame >= f32<-anim.keyframeCount:
            anim_current_frame = 0.0

        rl.UpdateModelAnimation(model, anim, anim_current_frame)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode3D(camera)
        if not rl.IsKeyDown(rl.KeyboardKey.KEY_SPACE):
            rl.DrawModel(model, position, 1.0, rl.WHITE)
        else:
            draw_model_skeleton(model.skeleton, model_animation_pose(anim, i32<-anim_current_frame), 1.0, rl.RED)

        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()

        rl.DrawText(rl.TextFormat(current_animation_format, model_animation_name(anims, anim_index)), 10, 10, 20, rl.LIGHTGRAY)
        rl.DrawText(skeleton_text, 10, 40, 20, rl.MAROON)
        rl.DrawText(credit_text, screen_width - 210, screen_height - 20, 10, rl.GRAY)

    return 0
