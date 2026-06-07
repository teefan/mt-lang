import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as rm
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const BONE_SOCKETS: int = 3
const BONE_SOCKET_HAT: int = 0
const BONE_SOCKET_HAND_R: int = 1
const BONE_SOCKET_HAND_L: int = 2
const DEG_TO_RAD: float = rl.PI / 180.0


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - bone socket")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 5.0, y = 5.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 2.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    var character_model = rl.load_model("models/gltf/greenman.glb")
    defer rl.unload_model(character_model)

    var equip_models: array[rl.Model, BONE_SOCKETS] = zero[array[rl.Model, BONE_SOCKETS]]
    equip_models[BONE_SOCKET_HAT] = rl.load_model("models/gltf/greenman_hat.glb")
    equip_models[BONE_SOCKET_HAND_R] = rl.load_model("models/gltf/greenman_sword.glb")
    equip_models[BONE_SOCKET_HAND_L] = rl.load_model("models/gltf/greenman_shield.glb")

    defer:
        var equip_index = 0
        while equip_index < BONE_SOCKETS:
            rl.unload_model(equip_models[equip_index])
            equip_index += 1

    var show_equip = array[bool, BONE_SOCKETS](true, true, true)

    var anim_count = 0
    let animations = rl.load_model_animations("models/gltf/greenman.glb", ptr_of(anim_count)) else:
        fatal("could not load greenman animations")
    defer rl.unload_model_animations(animations, anim_count)

    var anim_index = 0
    var anim_current_frame = 0

    var bone_socket_index = array[int, BONE_SOCKETS](-1, -1, -1)
    var bone_index = 0
    while bone_index < character_model.skeleton.boneCount:
        var bone = unsafe: character_model.skeleton.bones[bone_index]
        let bone_name = text.chars_as_str(ptr_of(bone.name[0]))
        if bone_name == "socket_hat":
            bone_socket_index[BONE_SOCKET_HAT] = bone_index
        else if bone_name == "socket_hand_R":
            bone_socket_index[BONE_SOCKET_HAND_R] = bone_index
        else if bone_name == "socket_hand_L":
            bone_socket_index[BONE_SOCKET_HAND_L] = bone_index
        bone_index += 1

    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
    var angle = 0

    rl.disable_cursor()
    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_THIRD_PERSON)

        if rl.is_key_down(rl.KeyboardKey.KEY_F):
            angle = (angle + 1) % 360
        else if rl.is_key_down(rl.KeyboardKey.KEY_H):
            angle = (360 + angle - 1) % 360

        if rl.is_key_pressed(rl.KeyboardKey.KEY_T):
            anim_index = (anim_index + 1) % anim_count
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_G):
            anim_index = (anim_index + anim_count - 1) % anim_count

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            show_equip[BONE_SOCKET_HAT] = not show_equip[BONE_SOCKET_HAT]
        if rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            show_equip[BONE_SOCKET_HAND_R] = not show_equip[BONE_SOCKET_HAND_R]
        if rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            show_equip[BONE_SOCKET_HAND_L] = not show_equip[BONE_SOCKET_HAND_L]

        let animation = unsafe: animations[anim_index]
        anim_current_frame = (anim_current_frame + 1) % animation.keyframeCount
        rl.update_model_animation(character_model, animation, float<-anim_current_frame)

        let character_rotate = rm.quaternion_from_axis_angle(
            rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
            float<-angle * DEG_TO_RAD
        )
        character_model.transform = rm.matrix_multiply(
            rm.quaternion_to_matrix(character_rotate),
            rm.matrix_translate(position.x, position.y, position.z)
        )
        rl.update_model_animation(character_model, animation, float<-anim_current_frame)

        let animation_pose = unsafe: animation.keyframePoses[anim_current_frame]

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_mesh(unsafe: character_model.meshes[0], unsafe: character_model.materials[1], character_model.transform)

        var socket_index = 0
        while socket_index < BONE_SOCKETS:
            if show_equip[socket_index] and bone_socket_index[socket_index] >= 0:
                let socket_bone_index = bone_socket_index[socket_index]
                let socket_transform = unsafe: animation_pose[socket_bone_index]
                let bind_pose = unsafe: character_model.skeleton.bindPose[socket_bone_index]
                let rotate = rm.quaternion_multiply(socket_transform.rotation, rm.quaternion_invert(bind_pose.rotation))

                var matrix_transform = rm.quaternion_to_matrix(rotate)
                matrix_transform = rm.matrix_multiply(
                    matrix_transform,
                    rm.matrix_translate(
                        socket_transform.translation.x,
                        socket_transform.translation.y,
                        socket_transform.translation.z
                    )
                )
                matrix_transform = rm.matrix_multiply(matrix_transform, character_model.transform)

                rl.draw_mesh(
                    unsafe: equip_models[socket_index].meshes[0],
                    unsafe: equip_models[socket_index].materials[1],
                    matrix_transform
                )
            socket_index += 1

        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        rl.draw_text("Use the T/G to switch animation", 10, 10, 20, rl.GRAY)
        rl.draw_text("Use the F/H to rotate character left/right", 10, 35, 20, rl.GRAY)
        rl.draw_text("Use the 1,2,3 to toggle shown of hat, sword and shield", 10, 60, 20, rl.GRAY)
        rl.end_drawing()

    return 0
