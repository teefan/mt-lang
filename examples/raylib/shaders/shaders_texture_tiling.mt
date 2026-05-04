module examples.raylib.shaders.shaders_texture_tiling

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const texture_path: cstr = c"../resources/cubicmap_atlas.png"
const shader_path_format: cstr = c"../resources/shaders/glsl%i/tiling.fs"
const tiling_uniform_name: cstr = c"tiling"
const help_text: cstr = c"Use mouse to rotate the camera"
const window_title: cstr = c"raylib [shaders] example - texture tiling"


def set_model_shader(model: ptr[rl.Model], shader: rl.Shader) -> void:
    unsafe:
        model.materials[0].shader = shader


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 4.0, y = 4.0, z = 4.0),
        target = rl.Vector3(x = 0.0, y = 0.5, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let cube = rl.GenMeshCube(1.0, 1.0, 1.0)
    var model = rl.LoadModelFromMesh(cube)
    defer rl.UnloadModel(model)

    let texture = rl.LoadTexture(texture_path)
    defer rl.UnloadTexture(texture)

    rl.SetMaterialTexture(model.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    var tiling = array[f32, 2](3.0, 3.0)
    let shader = rl.LoadShader(zero[cstr?], rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    rl.SetTextureWrap(texture, i32<-rl.TextureWrap.TEXTURE_WRAP_REPEAT)
    rl.SetShaderValue(shader, rl.GetShaderLocation(shader, tiling_uniform_name), ptr_of(tiling[0]), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
    set_model_shader(ptr_of(model), shader)

    rl.DisableCursor()
    defer rl.EnableCursor()

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(camera), rl.CameraMode.CAMERA_FREE)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_Z):
            camera.target = rl.Vector3(x = 0.0, y = 0.5, z = 0.0)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode3D(camera)
        rl.BeginShaderMode(shader)
        rl.DrawModel(model, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 2.0, rl.WHITE)
        rl.EndShaderMode()
        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()

        rl.DrawText(help_text, 10, 10, 20, rl.DARKGRAY)

    return 0
