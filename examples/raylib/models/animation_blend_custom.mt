import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as rm
import std.rlgl as rlgl
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function animation_name(animations: ptr[rl.ModelAnimation], index: int) -> str:
    var anim = unsafe: animations[index]
    return text.chars_as_str(ptr_of(anim.name[0]))


function is_upper_body_bone(bone_name: str) -> bool:
    return bone_name == "body_up" or bone_name == "hand_L" or bone_name == "hand_R" or bone_name == "socket_hat" or bone_name == "socket_hand_L" or bone_name == "socket_hand_R"


function update_model_animation_bones(model: rl.Model, anim0: rl.ModelAnimation, frame0: int, anim1: rl.ModelAnimation, frame1: int, blend: float, upper_body_blend: bool) -> void:
    if anim0.boneCount == 0:
        return
    if anim1.boneCount == 0:
        return
    if model.skeleton.boneCount == 0:
        return

    var clamped_blend = blend
    if clamped_blend < 0.0:
        clamped_blend = 0.0
    else if clamped_blend > 1.0:
        clamped_blend = 1.0

    var checked_frame0 = frame0
    if checked_frame0 >= anim0.keyframeCount:
        checked_frame0 = anim0.keyframeCount - 1
    if checked_frame0 < 0:
        checked_frame0 = 0

    var checked_frame1 = frame1
    if checked_frame1 >= anim1.keyframeCount:
        checked_frame1 = anim1.keyframeCount - 1
    if checked_frame1 < 0:
        checked_frame1 = 0

    var bone_count = model.skeleton.boneCount
    if anim0.boneCount < bone_count:
        bone_count = anim0.boneCount
    if anim1.boneCount < bone_count:
        bone_count = anim1.boneCount

    var bone_index = 0
    while bone_index < bone_count:
        var bone_blend_factor = clamped_blend
        if upper_body_blend:
            var bone = unsafe: model.skeleton.bones[bone_index]
            let bone_name = text.chars_as_str(ptr_of(bone.name[0]))
            if not is_upper_body_bone(bone_name):
                bone_blend_factor = 1.0 - clamped_blend

        let bind_transform = unsafe: model.skeleton.bindPose[bone_index]
        let anim_transform0 = unsafe: read(anim0.keyframePoses + ptr_uint<-checked_frame0)[bone_index]
        let anim_transform1 = unsafe: read(anim1.keyframePoses + ptr_uint<-checked_frame1)[bone_index]

        let blended = rl.Transform(
            translation = rm.vector3_lerp(anim_transform0.translation, anim_transform1.translation, bone_blend_factor),
            rotation = rm.quaternion_slerp(anim_transform0.rotation, anim_transform1.rotation, bone_blend_factor),
            scale = rm.vector3_lerp(anim_transform0.scale, anim_transform1.scale, bone_blend_factor),
        )

        let bind_matrix = rm.matrix_multiply(
            rm.matrix_multiply(
                rm.matrix_scale(bind_transform.scale.x, bind_transform.scale.y, bind_transform.scale.z),
                rm.quaternion_to_matrix(bind_transform.rotation),
            ),
            rm.matrix_translate(bind_transform.translation.x, bind_transform.translation.y, bind_transform.translation.z),
        )
        let blended_matrix = rm.matrix_multiply(
            rm.matrix_multiply(
                rm.matrix_scale(blended.scale.x, blended.scale.y, blended.scale.z),
                rm.quaternion_to_matrix(blended.rotation),
            ),
            rm.matrix_translate(blended.translation.x, blended.translation.y, blended.translation.z),
        )

        unsafe: read(model.boneMatrices + ptr_uint<-bone_index) = rm.matrix_multiply(rm.matrix_invert(bind_matrix), blended_matrix)
        bone_index += 1

    var mesh_index = 0
    while mesh_index < model.meshCount:
        let mesh = unsafe: model.meshes[mesh_index]
        if mesh.boneCount == 0:
            mesh_index += 1
            continue

        let vertex_values_count = mesh.vertexCount * 3
        var bone_counter = 0
        var buffer_update_required = false

        var vertex_counter = 0
        while vertex_counter < vertex_values_count:
            unsafe:
                read(mesh.animVertices + ptr_uint<-vertex_counter) = 0.0
                read(mesh.animVertices + ptr_uint<-(vertex_counter + 1)) = 0.0
                read(mesh.animVertices + ptr_uint<-(vertex_counter + 2)) = 0.0
                read(mesh.animNormals + ptr_uint<-vertex_counter) = 0.0
                read(mesh.animNormals + ptr_uint<-(vertex_counter + 1)) = 0.0
                read(mesh.animNormals + ptr_uint<-(vertex_counter + 2)) = 0.0

            var influence_index = 0
            while influence_index < 4:
                let bone_weight = unsafe: read(mesh.boneWeights + ptr_uint<-bone_counter)
                let current_bone_index = int<-(unsafe: read(mesh.boneIndices + ptr_uint<-bone_counter))
                bone_counter += 1
                if bone_weight == 0.0:
                    influence_index += 1
                    continue

                let anim_vertex = rm.vector3_transform(
                    rl.Vector3(
                        x = unsafe: read(mesh.vertices + ptr_uint<-vertex_counter),
                        y = unsafe: read(mesh.vertices + ptr_uint<-(vertex_counter + 1)),
                        z = unsafe: read(mesh.vertices + ptr_uint<-(vertex_counter + 2)),
                    ),
                    unsafe: read(model.boneMatrices + ptr_uint<-current_bone_index),
                )
                unsafe:
                    read(mesh.animVertices + ptr_uint<-vertex_counter) += anim_vertex.x * bone_weight
                    read(mesh.animVertices + ptr_uint<-(vertex_counter + 1)) += anim_vertex.y * bone_weight
                    read(mesh.animVertices + ptr_uint<-(vertex_counter + 2)) += anim_vertex.z * bone_weight
                buffer_update_required = true

                let normal_matrix = rm.matrix_transpose(rm.matrix_invert(unsafe: read(model.boneMatrices + ptr_uint<-current_bone_index)))
                let anim_normal = rm.vector3_transform(
                    rl.Vector3(
                        x = unsafe: read(mesh.normals + ptr_uint<-vertex_counter),
                        y = unsafe: read(mesh.normals + ptr_uint<-(vertex_counter + 1)),
                        z = unsafe: read(mesh.normals + ptr_uint<-(vertex_counter + 2)),
                    ),
                    normal_matrix,
                )
                unsafe:
                    read(mesh.animNormals + ptr_uint<-vertex_counter) += anim_normal.x * bone_weight
                    read(mesh.animNormals + ptr_uint<-(vertex_counter + 1)) += anim_normal.y * bone_weight
                    read(mesh.animNormals + ptr_uint<-(vertex_counter + 2)) += anim_normal.z * bone_weight

                influence_index += 1

            vertex_counter += 3

        if buffer_update_required:
            rlgl.update_vertex_buffer(
                unsafe: mesh.vboId[int<-rl.ShaderLocationIndex.SHADER_LOC_VERTEX_POSITION],
                mesh.animVertices,
                mesh.vertexCount * 3 * int<-size_of(float),
                0,
            )
            rlgl.update_vertex_buffer(
                unsafe: mesh.vboId[int<-rl.ShaderLocationIndex.SHADER_LOC_VERTEX_NORMAL],
                mesh.animNormals,
                mesh.vertexCount * 3 * int<-size_of(float),
                0,
            )

        mesh_index += 1


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - animation blend custom")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 4.0, y = 4.0, z = 4.0),
        target = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var model = rl.load_model("models/gltf/greenman.glb")
    defer rl.unload_model(model)
    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    let skinning_vertex_shader = rl.text_format("shaders/glsl%i/skinning.vs", GLSL_VERSION)
    let skinning_fragment_shader = rl.text_format("shaders/glsl%i/skinning.fs", GLSL_VERSION)
    let skinning_shader = rl.load_shader(skinning_vertex_shader, skinning_fragment_shader)
    defer rl.unload_shader(skinning_shader)
    unsafe: model.materials[1].shader = skinning_shader

    var anim_count = 0
    let animations = rl.load_model_animations("models/gltf/greenman.glb", ptr_of(anim_count)) else:
        fatal("could not load greenman animations")
    defer rl.unload_model_animations(animations, anim_count)

    var anim_index0 = 2
    var anim_index1 = 3
    if anim_index0 >= anim_count:
        anim_index0 = 0
    if anim_index1 >= anim_count:
        if anim_count > 1:
            anim_index1 = 1
        else:
            anim_index1 = 0

    var anim_current_frame0 = 0
    var anim_current_frame1 = 0
    var upper_body_blend = true

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            upper_body_blend = not upper_body_blend

        let anim0 = unsafe: animations[anim_index0]
        let anim1 = unsafe: animations[anim_index1]

        anim_current_frame0 = (anim_current_frame0 + 1) % anim0.keyframeCount
        anim_current_frame1 = (anim_current_frame1 + 1) % anim1.keyframeCount

        var blend_factor = float<-0.5
        if upper_body_blend:
            blend_factor = 1.0
        update_model_animation_bones(model, anim0, anim_current_frame0, anim1, anim_current_frame1, blend_factor, upper_body_blend)

        let anim0_text = rl.text_format("ANIM 0: %s", animation_name(animations, anim_index0))
        let anim1_text = rl.text_format("ANIM 1: %s", animation_name(animations, anim_index1))
        let blend_mode_label = if upper_body_blend: "Upper/Lower Body Blending" else: "Uniform Blending"
        let blend_mode_text = rl.text_format("[SPACE] Toggle blending mode: %s", blend_mode_label)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_model(model, position, 1.0, rl.WHITE)
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        rl.draw_text(anim0_text, 10, 10, 20, rl.GRAY)
        rl.draw_text(anim1_text, 10, 40, 20, rl.GRAY)
        rl.draw_text(blend_mode_text, 10, rl.get_screen_height() - 30, 20, rl.DARKGRAY)
        rl.end_drawing()

    return 0
