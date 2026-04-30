module examples.raylib.shaders.shaders_texture_rendering

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const shader_path_format: cstr = c"../resources/shaders/glsl%i/cubes_panning.fs"
const background_text: cstr = c"BACKGROUND is PAINTED and ANIMATED on SHADER!"
const shader_time_name: cstr = c"uTime"
const window_title: cstr = c"raylib [shaders] example - texture rendering"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let blank_image = rl.GenImageColor(1024, 1024, rl.BLANK)
    let texture = rl.LoadTextureFromImage(blank_image)
    rl.UnloadImage(blank_image)
    defer rl.UnloadTexture(texture)

    let shader = rl.LoadShader(zero[cstr?](), rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    var time: f32 = 0.0
    let time_loc = rl.GetShaderLocation(shader, shader_time_name)
    rl.SetShaderValue(shader, time_loc, ptr_of(ref_of(time)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        time = f32<-rl.GetTime()
        rl.SetShaderValue(shader, time_loc, ptr_of(ref_of(time)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginShaderMode(shader)
        rl.DrawTexture(texture, 0, 0, rl.WHITE)
        rl.EndShaderMode()

        rl.DrawText(background_text, 10, 10, 20, rl.MAROON)

    return 0
