module examples.raylib.shaders.shaders_model_shader

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const model_path: cstr = c"../resources/models/watermill.obj"
const texture_path: cstr = c"../resources/models/watermill_diffuse.png"
const shader_path_format: cstr = c"../resources/shaders/glsl%i/grayscale.fs"
const credit_text: cstr = c"(c) Watermill 3D model by Alberto Cano"
const window_title: cstr = c"raylib [shaders] example - model shader"

def set_model_shader(model: ptr[rl.Model], shader: rl.Shader) -> void:
    unsafe:
        deref(model).materials[0].shader = shader

def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)

    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 4.0, y = 4.0, z = 4.0),
        target = rl.Vector3(x = 0.0, y = 1.0, z = -1.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var model = rl.LoadModel(model_path)
    defer rl.UnloadModel(model)

    let texture = rl.LoadTexture(texture_path)
    defer rl.UnloadTexture(texture)

    let shader = rl.LoadShader(zero[cstr?](), rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    set_model_shader(raw(addr(model)), shader)
    rl.SetMaterialTexture(model.materials, cast[i32](rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO), texture)

    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    rl.DisableCursor()
    defer rl.EnableCursor()
    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(raw(addr(camera)), rl.CameraMode.CAMERA_FREE)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode3D(camera)
        rl.DrawModel(model, position, 0.2, rl.WHITE)
        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()

        rl.DrawText(credit_text, screen_width - 210, screen_height - 20, 10, rl.GRAY)
        rl.DrawFPS(10, 10)

    return 0
