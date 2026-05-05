module examples.raylib.shaders.shaders_multi_sample2d

import std.c.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const glsl_version: int = 330
const shader_path_format: cstr = c"../resources/shaders/glsl%i/color_mix.fs"
const texture_uniform_name: cstr = c"texture1"
const divider_uniform_name: cstr = c"divider"
const help_text: cstr = c"Use KEY_LEFT/KEY_RIGHT to move texture mixing in shader!"
const window_title: cstr = c"raylib [shaders] example - multi sample2d"


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let red_image = rl.GenImageColor(screen_width, screen_height, rl.Color(r = 255, g = 0, b = 0, a = 255))
    let red_texture = rl.LoadTextureFromImage(red_image)
    rl.UnloadImage(red_image)
    defer rl.UnloadTexture(red_texture)

    let blue_image = rl.GenImageColor(screen_width, screen_height, rl.Color(r = 0, g = 0, b = 255, a = 255))
    let blue_texture = rl.LoadTextureFromImage(blue_image)
    rl.UnloadImage(blue_image)
    defer rl.UnloadTexture(blue_texture)

    let shader = rl.LoadShader(zero[cstr?], rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    let blue_texture_location = rl.GetShaderLocation(shader, texture_uniform_name)
    let divider_location = rl.GetShaderLocation(shader, divider_uniform_name)
    var divider_value: float = 0.5

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT):
            divider_value += 0.01
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT):
            divider_value -= 0.01

        if divider_value < 0.0:
            divider_value = 0.0
        elif divider_value > 1.0:
            divider_value = 1.0

        rl.SetShaderValue(shader, divider_location, ptr_of(divider_value), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginShaderMode(shader)
        rl.SetShaderValueTexture(shader, blue_texture_location, blue_texture)
        rl.DrawTexture(red_texture, 0, 0, rl.WHITE)
        rl.EndShaderMode()

        rl.DrawText(help_text, 80, rl.GetScreenHeight() - 40, 20, rl.RAYWHITE)

    return 0
