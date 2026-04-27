module examples.raylib.shaders.shaders_eratosthenes_sieve

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const shader_path_format: cstr = c"resources/shaders/glsl%i/eratosthenes.fs"
const window_title: cstr = c"raylib [shaders] example - eratosthenes sieve"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let target = rl.LoadRenderTexture(screen_width, screen_height)
    defer rl.UnloadRenderTexture(target)

    let shader = rl.LoadShader(zero[cstr?](), rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.BeginTextureMode(target)
        rl.ClearBackground(rl.BLACK)
        rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), rl.BLACK)
        rl.EndTextureMode()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginShaderMode(shader)
        rl.DrawTextureRec(
            target.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = cast[f32](target.texture.width), height = -cast[f32](target.texture.height)),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE,
        )
        rl.EndShaderMode()

    return 0
