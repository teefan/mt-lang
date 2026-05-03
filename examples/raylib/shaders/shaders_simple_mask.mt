module examples.raylib.shaders.shaders_simple_mask

import std.c.raylib as rl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const shader_path_format: cstr = c"../resources/shaders/glsl%i/mask.fs"
const diffuse_texture_path: cstr = c"../resources/plasma.png"
const mask_texture_path: cstr = c"../resources/mask.png"
const mask_uniform_name: cstr = c"mask"
const frame_uniform_name: cstr = c"frame"
const frame_format: cstr = c"Frame: %i"
const window_title: cstr = c"raylib [shaders] example - simple mask"


def set_model_shader(model: ptr[rl.Model], shader: rl.Shader) -> void:
    unsafe:
        model.materials[0].shader = shader


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 0.0, y = 1.0, z = 2.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let torus = rl.GenMeshTorus(0.3, 1.0, 16, 32)
    var model1 = rl.LoadModelFromMesh(torus)
    defer rl.UnloadModel(model1)

    let cube = rl.GenMeshCube(0.8, 0.8, 0.8)
    var model2 = rl.LoadModelFromMesh(cube)
    defer rl.UnloadModel(model2)

    let sphere = rl.GenMeshSphere(1.0, 16, 16)
    let model3 = rl.LoadModelFromMesh(sphere)
    defer rl.UnloadModel(model3)

    var shader = rl.LoadShader(zero[cstr?](), rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    let tex_diffuse = rl.LoadTexture(diffuse_texture_path)
    defer rl.UnloadTexture(tex_diffuse)
    rl.SetMaterialTexture(model1.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, tex_diffuse)
    rl.SetMaterialTexture(model2.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, tex_diffuse)

    let tex_mask = rl.LoadTexture(mask_texture_path)
    defer rl.UnloadTexture(tex_mask)
    rl.SetMaterialTexture(model1.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_EMISSION, tex_mask)
    rl.SetMaterialTexture(model2.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_EMISSION, tex_mask)

    unsafe:
        shader.locs[i32<-rl.ShaderLocationIndex.SHADER_LOC_MAP_EMISSION] = rl.GetShaderLocation(shader, mask_uniform_name)

    let shader_frame = rl.GetShaderLocation(shader, frame_uniform_name)
    set_model_shader(ptr_of(ref_of(model1)), shader)
    set_model_shader(ptr_of(ref_of(model2)), shader)

    var frames_counter = 0
    var rotation = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    rl.DisableCursor()
    defer rl.EnableCursor()
    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(ref_of(camera)), rl.CameraMode.CAMERA_FIRST_PERSON)

        frames_counter += 1
        rotation.x += 0.01
        rotation.y += 0.005
        rotation.z -= 0.0025

        rl.SetShaderValue(shader, shader_frame, ptr_of(ref_of(frames_counter)), rl.ShaderUniformDataType.SHADER_UNIFORM_INT)
        model1.transform = rm.Matrix.rotate_xyz(rotation)

        let frame_text = rl.TextFormat(frame_format, frames_counter)
        let frame_width = rl.MeasureText(frame_text, 20)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.DARKBLUE)

        rl.BeginMode3D(camera)
        rl.DrawModel(model1, rl.Vector3(x = 0.5, y = 0.0, z = 0.0), 1.0, rl.WHITE)
        rl.DrawModelEx(
            model2,
            rl.Vector3(x = -0.5, y = 0.0, z = 0.0),
            rl.Vector3(x = 1.0, y = 1.0, z = 0.0),
            50.0,
            rl.Vector3(x = 1.0, y = 1.0, z = 1.0),
            rl.WHITE,
        )
        rl.DrawModel(model3, rl.Vector3(x = 0.0, y = 0.0, z = -1.5), 1.0, rl.WHITE)
        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()

        rl.DrawRectangle(16, 698, frame_width + 8, 42, rl.BLUE)
        rl.DrawText(frame_text, 20, 700, 20, rl.WHITE)
        rl.DrawFPS(10, 10)

    return 0
