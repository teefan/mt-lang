module examples.raylib.shaders.shaders_custom_uniform

import std.c.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const screen_height_f: float = 450.0
const glsl_version: int = 330
const model_path: cstr = c"../resources/models/barracks.obj"
const texture_path: cstr = c"../resources/models/barracks_diffuse.png"
const shader_path_format: cstr = c"../resources/shaders/glsl%i/swirl.fs"
const swirl_center_uniform_name: cstr = c"center"
const render_texture_text: cstr = c"TEXT DRAWN IN RENDER TEXTURE"
const credit_text: cstr = c"(c) Barracks 3D model by Alberto Cano"
const window_title: cstr = c"raylib [shaders] example - custom uniform"


def main() -> int:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)

    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 8.0, y = 8.0, z = 8.0),
        target = rl.Vector3(x = 0.0, y = 1.5, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var model = rl.LoadModel(model_path)
    defer rl.UnloadModel(model)

    let texture = rl.LoadTexture(texture_path)
    defer rl.UnloadTexture(texture)
    rl.SetMaterialTexture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
    let shader = rl.LoadShader(zero[cstr?], rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    let swirl_center_loc = rl.GetShaderLocation(shader, swirl_center_uniform_name)
    var swirl_center = array[float, 2](400.0, 225.0)

    let target = rl.LoadRenderTexture(screen_width, screen_height)
    defer rl.UnloadRenderTexture(target)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(camera), rl.CameraMode.CAMERA_ORBITAL)

        let mouse_position = rl.GetMousePosition()
        swirl_center[0] = mouse_position.x
        swirl_center[1] = screen_height_f - mouse_position.y
        rl.SetShaderValue(shader, swirl_center_loc, ptr_of(swirl_center[0]), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

        rl.BeginTextureMode(target)
        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)
        rl.DrawModel(model, position, 0.5, rl.WHITE)
        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()
        rl.DrawText(render_texture_text, 200, 10, 30, rl.RED)
        rl.EndTextureMode()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginShaderMode(shader)
        rl.DrawTextureRec(
            target.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = float<-target.texture.width, height = -float<-target.texture.height),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE,
        )
        rl.EndShaderMode()

        rl.DrawText(credit_text, screen_width - 220, screen_height - 20, 10, rl.GRAY)
        rl.DrawFPS(10, 10)

    return 0
