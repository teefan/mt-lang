module examples.raylib.models.models_bone_socket

import std.c.raylib as rl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const bone_sockets: i32 = 3
const bone_socket_hat: i32 = 0
const bone_socket_hand_r: i32 = 1
const bone_socket_hand_l: i32 = 2
const character_model_path: cstr = c"../resources/models/gltf/greenman.glb"
const hat_model_path: cstr = c"../resources/models/gltf/greenman_hat.glb"
const sword_model_path: cstr = c"../resources/models/gltf/greenman_sword.glb"
const shield_model_path: cstr = c"../resources/models/gltf/greenman_shield.glb"
const hat_socket_name: cstr = c"socket_hat"
const hand_r_socket_name: cstr = c"socket_hand_R"
const hand_l_socket_name: cstr = c"socket_hand_L"
const switch_text: cstr = c"Use the T/G to switch animation"
const rotate_text: cstr = c"Use the F/H to rotate character left/right"
const toggle_text: cstr = c"Use the 1,2,3 to toggle shown of hat, sword and shield"
const window_title: cstr = c"raylib [models] example - bone socket"


def chars_to_cstr(text: ptr[char]) -> cstr:
    unsafe:
        return cstr<-text


def model_animation(anims: ptr[rl.ModelAnimation], index: i32) -> rl.ModelAnimation:
    unsafe:
        return read(anims + index)


def model_animation_pose(anim: rl.ModelAnimation, frame: i32) -> rl.ModelAnimPose:
    unsafe:
        return read(anim.keyframePoses + frame)


def pose_transform(pose: rl.ModelAnimPose, index: i32) -> rl.Transform:
    unsafe:
        return read(pose + index)


def skeleton_bone_name(skeleton: rl.ModelSkeleton, index: i32) -> cstr:
    unsafe:
        return chars_to_cstr(ptr_of(ref_of((skeleton.bones + index).name[0])))


def bind_pose_transform(skeleton: rl.ModelSkeleton, index: i32) -> rl.Transform:
    unsafe:
        return read(skeleton.bindPose + index)


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 5.0, y = 5.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 2.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var character_model = rl.LoadModel(character_model_path)
    defer rl.UnloadModel(character_model)

    var equip_models = zero[array[rl.Model, bone_sockets]]()
    equip_models[bone_socket_hat] = rl.LoadModel(hat_model_path)
    equip_models[bone_socket_hand_r] = rl.LoadModel(sword_model_path)
    equip_models[bone_socket_hand_l] = rl.LoadModel(shield_model_path)
    defer:
        for index in range(0, bone_sockets):
            rl.UnloadModel(equip_models[index])

    var show_equip = array[bool, bone_sockets](true, true, true)

    var anims_count = 0
    let model_animations = rl.LoadModelAnimations(character_model_path, ptr_of(ref_of(anims_count)))
    defer rl.UnloadModelAnimations(model_animations, anims_count)

    var anim_index = 0
    var anim_current_frame = 0

    var bone_socket_index = array[i32, bone_sockets](-1, -1, -1)
    for index in range(0, character_model.skeleton.boneCount):
        let name = skeleton_bone_name(character_model.skeleton, index)
        if rl.TextIsEqual(name, hat_socket_name):
            bone_socket_index[bone_socket_hat] = index
            continue
        if rl.TextIsEqual(name, hand_r_socket_name):
            bone_socket_index[bone_socket_hand_r] = index
            continue
        if rl.TextIsEqual(name, hand_l_socket_name):
            bone_socket_index[bone_socket_hand_l] = index

    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
    var angle = 0

    rl.DisableCursor()
    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(ref_of(camera)), rl.CameraMode.CAMERA_THIRD_PERSON)

        if rl.IsKeyDown(rl.KeyboardKey.KEY_F):
            angle = (angle + 1) % 360
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_H):
            angle = (360 + angle - 1) % 360

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_T):
            anim_index = (anim_index + 1) % anims_count
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_G):
            anim_index = (anim_index + anims_count - 1) % anims_count

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_ONE):
            show_equip[bone_socket_hat] = not show_equip[bone_socket_hat]
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_TWO):
            show_equip[bone_socket_hand_r] = not show_equip[bone_socket_hand_r]
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_THREE):
            show_equip[bone_socket_hand_l] = not show_equip[bone_socket_hand_l]

        let anim = model_animation(model_animations, anim_index)
        anim_current_frame = (anim_current_frame + 1) % anim.keyframeCount
        rl.UpdateModelAnimation(character_model, anim, f32<-anim_current_frame)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)

        let character_rotate = rm.Quaternion.from_axis_angle(rl.Vector3(x = 0.0, y = 1.0, z = 0.0), f32<-angle * rm.deg2rad)
        character_model.transform = character_rotate.to_matrix().multiply(rm.Matrix.translate(position.x, position.y, position.z))
        rl.UpdateModelAnimation(character_model, anim, f32<-anim_current_frame)

        unsafe:
            rl.DrawMesh(character_model.meshes[0], character_model.materials[1], character_model.transform)

        let pose = model_animation_pose(anim, anim_current_frame)
        for index in range(0, bone_sockets):
            if not show_equip[index]:
                continue

            let socket_index = bone_socket_index[index]
            if socket_index < 0:
                continue

            let transform = pose_transform(pose, socket_index)
            let in_rotation = bind_pose_transform(character_model.skeleton, socket_index).rotation
            let out_rotation = transform.rotation
            let rotate = out_rotation.multiply(in_rotation.invert())

            var matrix_transform = rotate.to_matrix()
            matrix_transform = matrix_transform.multiply(rm.Matrix.translate(transform.translation.x, transform.translation.y, transform.translation.z))
            matrix_transform = matrix_transform.multiply(character_model.transform)

            unsafe:
                rl.DrawMesh(equip_models[index].meshes[0], equip_models[index].materials[1], matrix_transform)

        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()

        rl.DrawText(switch_text, 10, 10, 20, rl.GRAY)
        rl.DrawText(rotate_text, 10, 35, 20, rl.GRAY)
        rl.DrawText(toggle_text, 10, 60, 20, rl.GRAY)

    return 0
