module examples.raylib.models.models_animation_blend_custom

import std.c.raylib as rl
import std.c.rlgl as rlgl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const model_path: cstr = c"../resources/models/gltf/greenman.glb"
const shader_vertex_path_format: cstr = c"../resources/shaders/glsl%i/skinning.vs"
const shader_fragment_path_format: cstr = c"../resources/shaders/glsl%i/skinning.fs"
const anim0_format: cstr = c"ANIM 0: %s"
const anim1_format: cstr = c"ANIM 1: %s"
const mode_format: cstr = c"[SPACE] Toggle blending mode: %s"
const upper_body_mode_text: cstr = c"Upper/Lower Body Blending"
const uniform_mode_text: cstr = c"Uniform Blending"
const window_title: cstr = c"raylib [models] example - animation blend custom"

def chars_to_cstr(text: ptr[char]) -> cstr:
    unsafe:
        return cstr<-text

def model_animation(anims: ptr[rl.ModelAnimation], index: i32) -> rl.ModelAnimation:
    unsafe:
        return deref(anims + index)

def model_animation_name(anims: ptr[rl.ModelAnimation], index: i32) -> cstr:
    unsafe:
        return chars_to_cstr(raw(addr(deref(anims + index).name[0])))

def model_animation_pose(anim: rl.ModelAnimation, frame: i32) -> rl.ModelAnimPose:
    unsafe:
        return deref(anim.keyframePoses + frame)

def pose_transform(pose: rl.ModelAnimPose, index: i32) -> rl.Transform:
    unsafe:
        return deref(pose + index)

def bind_pose_transform(skeleton: rl.ModelSkeleton, index: i32) -> rl.Transform:
    unsafe:
        return deref(skeleton.bindPose + index)

def skeleton_bone_name(skeleton: rl.ModelSkeleton, index: i32) -> cstr:
    unsafe:
        return chars_to_cstr(raw(addr(deref(skeleton.bones + index).name[0])))

def model_value(model: ptr[rl.Model]) -> rl.Model:
    unsafe:
        return deref(model)

def model_mesh(model: rl.Model, index: i32) -> rl.Mesh:
    unsafe:
        return model.meshes[index]

def model_bone_matrix(model: rl.Model, index: i32) -> rl.Matrix:
    unsafe:
        return deref(model.boneMatrices + index)

def set_model_bone_matrix(model: rl.Model, index: i32, matrix: rl.Matrix) -> void:
    unsafe:
        deref(model.boneMatrices + index) = matrix

def read_f32(values: ptr[f32], index: i32) -> f32:
    unsafe:
        return deref(values + index)

def write_f32(values: ptr[f32], index: i32, value: f32) -> void:
    unsafe:
        deref(values + index) = value

def read_u8(values: ptr[u8], index: i32) -> u8:
    unsafe:
        return deref(values + index)

def mesh_vbo_id(mesh: rl.Mesh, index: i32) -> u32:
    unsafe:
        return deref(mesh.vboId + index)

def is_upper_body_bone(bone_name: cstr) -> bool:
    if rl.TextIsEqual(bone_name, c"spine") or rl.TextIsEqual(bone_name, c"spine1") or rl.TextIsEqual(bone_name, c"spine2"):
        return true
    if rl.TextIsEqual(bone_name, c"chest") or rl.TextIsEqual(bone_name, c"upperChest"):
        return true
    if rl.TextIsEqual(bone_name, c"neck") or rl.TextIsEqual(bone_name, c"head"):
        return true
    if rl.TextIsEqual(bone_name, c"shoulder") or rl.TextIsEqual(bone_name, c"shoulder_L") or rl.TextIsEqual(bone_name, c"shoulder_R"):
        return true
    if rl.TextIsEqual(bone_name, c"upperArm") or rl.TextIsEqual(bone_name, c"upperArm_L") or rl.TextIsEqual(bone_name, c"upperArm_R"):
        return true
    if rl.TextIsEqual(bone_name, c"lowerArm") or rl.TextIsEqual(bone_name, c"lowerArm_L") or rl.TextIsEqual(bone_name, c"lowerArm_R"):
        return true
    if rl.TextIsEqual(bone_name, c"hand") or rl.TextIsEqual(bone_name, c"hand_L") or rl.TextIsEqual(bone_name, c"hand_R"):
        return true
    if rl.TextIsEqual(bone_name, c"clavicle") or rl.TextIsEqual(bone_name, c"clavicle_L") or rl.TextIsEqual(bone_name, c"clavicle_R"):
        return true

    if rl.TextFindIndex(bone_name, c"spine") >= 0 or rl.TextFindIndex(bone_name, c"chest") >= 0:
        return true
    if rl.TextFindIndex(bone_name, c"neck") >= 0 or rl.TextFindIndex(bone_name, c"head") >= 0:
        return true
    if rl.TextFindIndex(bone_name, c"shoulder") >= 0 or rl.TextFindIndex(bone_name, c"arm") >= 0:
        return true
    if rl.TextFindIndex(bone_name, c"hand") >= 0 or rl.TextFindIndex(bone_name, c"clavicle") >= 0:
        return true

    return false

def update_model_animation_bones(model: ptr[rl.Model], anim0: rl.ModelAnimation, frame0: i32, anim1: rl.ModelAnimation, frame1: i32, blend: f32, upper_body_blend: bool) -> void:
    let current_model = model_value(model)
    let pose0 = model_animation_pose(anim0, frame0)
    let pose1 = model_animation_pose(anim1, frame1)
    let clamped_blend = rm.clamp(blend, 0.0, 1.0)

    for bone_index in range(0, current_model.skeleton.boneCount):
        var bone_blend_factor = clamped_blend
        if upper_body_blend:
            if is_upper_body_bone(skeleton_bone_name(current_model.skeleton, bone_index)):
                bone_blend_factor = clamped_blend
            else:
                bone_blend_factor = f32<-1.0 - clamped_blend

        let bind_transform = bind_pose_transform(current_model.skeleton, bone_index)
        let anim_transform0 = pose_transform(pose0, bone_index)
        let anim_transform1 = pose_transform(pose1, bone_index)

        let blended_translation = anim_transform0.translation.lerp(anim_transform1.translation, bone_blend_factor)
        let blended_rotation = anim_transform0.rotation.slerp(anim_transform1.rotation, bone_blend_factor)
        let blended_scale = anim_transform0.scale.lerp(anim_transform1.scale, bone_blend_factor)

        let bind_scale = rm.Matrix.scale(bind_transform.scale.x, bind_transform.scale.y, bind_transform.scale.z)
        let bind_rotation = bind_transform.rotation.to_matrix()
        let bind_translation = rm.Matrix.translate(bind_transform.translation.x, bind_transform.translation.y, bind_transform.translation.z)
        let bind_matrix = bind_scale.multiply(bind_rotation).multiply(bind_translation)

        let blended_scale_matrix = rm.Matrix.scale(blended_scale.x, blended_scale.y, blended_scale.z)
        let blended_rotation_matrix = blended_rotation.to_matrix()
        let blended_translation_matrix = rm.Matrix.translate(blended_translation.x, blended_translation.y, blended_translation.z)
        let blended_matrix = blended_scale_matrix.multiply(blended_rotation_matrix).multiply(blended_translation_matrix)

        set_model_bone_matrix(current_model, bone_index, bind_matrix.invert().multiply(blended_matrix))

    for mesh_index in range(0, current_model.meshCount):
        let mesh = model_mesh(current_model, mesh_index)
        let vertex_values_count = mesh.vertexCount * 3

        var bone_counter = 0
        var v_counter = 0
        var buffer_update_required = false
        while v_counter < vertex_values_count:
            write_f32(mesh.animVertices, v_counter, 0.0)
            write_f32(mesh.animVertices, v_counter + 1, 0.0)
            write_f32(mesh.animVertices, v_counter + 2, 0.0)
            write_f32(mesh.animNormals, v_counter, 0.0)
            write_f32(mesh.animNormals, v_counter + 1, 0.0)
            write_f32(mesh.animNormals, v_counter + 2, 0.0)

            for _ in range(0, 4):
                let bone_weight = read_f32(mesh.boneWeights, bone_counter)
                let bone_index = i32<-read_u8(mesh.boneIndices, bone_counter)

                if bone_weight != 0.0:
                    let bone_matrix = model_bone_matrix(current_model, bone_index)
                    let anim_vertex = rl.Vector3(
                        x = read_f32(mesh.vertices, v_counter),
                        y = read_f32(mesh.vertices, v_counter + 1),
                        z = read_f32(mesh.vertices, v_counter + 2),
                    ).transform(bone_matrix)

                    write_f32(mesh.animVertices, v_counter, read_f32(mesh.animVertices, v_counter) + anim_vertex.x * bone_weight)
                    write_f32(mesh.animVertices, v_counter + 1, read_f32(mesh.animVertices, v_counter + 1) + anim_vertex.y * bone_weight)
                    write_f32(mesh.animVertices, v_counter + 2, read_f32(mesh.animVertices, v_counter + 2) + anim_vertex.z * bone_weight)
                    buffer_update_required = true

                    let normal_matrix = bone_matrix.invert().transpose()
                    let anim_normal = rl.Vector3(
                        x = read_f32(mesh.normals, v_counter),
                        y = read_f32(mesh.normals, v_counter + 1),
                        z = read_f32(mesh.normals, v_counter + 2),
                    ).transform(normal_matrix)

                    write_f32(mesh.animNormals, v_counter, read_f32(mesh.animNormals, v_counter) + anim_normal.x * bone_weight)
                    write_f32(mesh.animNormals, v_counter + 1, read_f32(mesh.animNormals, v_counter + 1) + anim_normal.y * bone_weight)
                    write_f32(mesh.animNormals, v_counter + 2, read_f32(mesh.animNormals, v_counter + 2) + anim_normal.z * bone_weight)

                bone_counter += 1

            v_counter += 3

        if buffer_update_required:
            rlgl.rlUpdateVertexBuffer(
                mesh_vbo_id(mesh, i32<-rl.ShaderLocationIndex.SHADER_LOC_VERTEX_POSITION),
                mesh.animVertices,
                mesh.vertexCount * 3 * 4,
                0,
            )
            rlgl.rlUpdateVertexBuffer(
                mesh_vbo_id(mesh, i32<-rl.ShaderLocationIndex.SHADER_LOC_VERTEX_NORMAL),
                mesh.animNormals,
                mesh.vertexCount * 3 * 4,
                0,
            )

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 4.0, y = 4.0, z = 4.0),
        target = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var model = rl.LoadModel(model_path)
    defer rl.UnloadModel(model)
    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    let skinning_shader = rl.LoadShader(
        rl.TextFormat(shader_vertex_path_format, glsl_version),
        rl.TextFormat(shader_fragment_path_format, glsl_version),
    )
    defer rl.UnloadShader(skinning_shader)
    unsafe:
        model.materials[1].shader = skinning_shader

    var anim_count = 0
    let anims = rl.LoadModelAnimations(model_path, raw(addr(anim_count)))
    defer rl.UnloadModelAnimations(anims, anim_count)

    var anim_index0 = 2
    var anim_index1 = 3
    var anim_current_frame0 = 0
    var anim_current_frame1 = 0

    if anim_index0 >= anim_count:
        anim_index0 = 0
    if anim_index1 >= anim_count:
        anim_index1 = if anim_count > 1 then 1 else 0

    var upper_body_blend = true

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(raw(addr(camera)), rl.CameraMode.CAMERA_ORBITAL)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            upper_body_blend = not upper_body_blend

        let anim0 = model_animation(anims, anim_index0)
        let anim1 = model_animation(anims, anim_index1)

        anim_current_frame0 = (anim_current_frame0 + 1) % anim0.keyframeCount
        anim_current_frame1 = (anim_current_frame1 + 1) % anim1.keyframeCount

        let blend_factor = if upper_body_blend then f32<-1.0 else f32<-0.5
        update_model_animation_bones(raw(addr(model)), anim0, anim_current_frame0, anim1, anim_current_frame1, blend_factor, upper_body_blend)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)
        rl.DrawModel(model, position, 1.0, rl.WHITE)
        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()

        rl.DrawText(rl.TextFormat(anim0_format, model_animation_name(anims, anim_index0)), 10, 10, 20, rl.GRAY)
        rl.DrawText(rl.TextFormat(anim1_format, model_animation_name(anims, anim_index1)), 10, 40, 20, rl.GRAY)
        rl.DrawText(rl.TextFormat(mode_format, if upper_body_blend then upper_body_mode_text else uniform_mode_text), 10, rl.GetScreenHeight() - 30, 20, rl.DARKGRAY)

    return 0
