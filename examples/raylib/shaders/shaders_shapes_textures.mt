module examples.raylib.shaders.shaders_shapes_textures

import std.c.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const glsl_version: int = 330
const texture_path: cstr = c"../resources/fudesumi.png"
const shader_path_format: cstr = c"../resources/shaders/glsl%i/grayscale.fs"
const default_shader_text: cstr = c"USING DEFAULT SHADER"
const custom_shader_text: cstr = c"USING CUSTOM SHADER"
const credit_text: cstr = c"(c) Fudesumi sprite by Eiden Marsal"
const window_title: cstr = c"raylib [shaders] example - shapes textures"


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let fudesumi = rl.LoadTexture(texture_path)
    defer rl.UnloadTexture(fudesumi)

    let shader = rl.LoadShader(zero[cstr?], rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawText(default_shader_text, 20, 40, 10, rl.RED)

        rl.DrawCircle(80, 120, 35.0, rl.DARKBLUE)
        rl.DrawCircleGradient(rl.Vector2(x = 80.0, y = 220.0), 60.0, rl.GREEN, rl.SKYBLUE)
        rl.DrawCircleLines(80, 340, 80.0, rl.DARKBLUE)

        rl.BeginShaderMode(shader)
        rl.DrawText(custom_shader_text, 190, 40, 10, rl.RED)
        rl.DrawRectangle(190, 90, 120, 60, rl.RED)
        rl.DrawRectangleGradientH(160, 170, 180, 130, rl.MAROON, rl.GOLD)
        rl.DrawRectangleLines(210, 320, 80, 60, rl.ORANGE)
        rl.EndShaderMode()

        rl.DrawText(default_shader_text, 370, 40, 10, rl.RED)

        rl.DrawTriangle(
            rl.Vector2(x = 430.0, y = 80.0),
            rl.Vector2(x = 370.0, y = 150.0),
            rl.Vector2(x = 490.0, y = 150.0),
            rl.VIOLET,
        )
        rl.DrawTriangleLines(
            rl.Vector2(x = 430.0, y = 160.0),
            rl.Vector2(x = 410.0, y = 230.0),
            rl.Vector2(x = 450.0, y = 230.0),
            rl.DARKBLUE,
        )
        rl.DrawPoly(rl.Vector2(x = 430.0, y = 320.0), 6, 80.0, 0.0, rl.BROWN)

        rl.BeginShaderMode(shader)
        rl.DrawTexture(fudesumi, 500, -30, rl.WHITE)
        rl.EndShaderMode()

        rl.DrawText(credit_text, 380, screen_height - 20, 10, rl.GRAY)

    return 0
