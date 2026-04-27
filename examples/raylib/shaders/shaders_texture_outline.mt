module examples.raylib.shaders.shaders_texture_outline

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const texture_path: cstr = c"resources/fudesumi.png"
const shader_path_format: cstr = c"resources/shaders/glsl%i/outline.fs"
const outline_size_uniform_name: cstr = c"outlineSize"
const outline_color_uniform_name: cstr = c"outlineColor"
const texture_size_uniform_name: cstr = c"textureSize"
const title_text: cstr = c"Shader-based\ntexture\noutline"
const help_text: cstr = c"Scroll mouse wheel to\nchange outline size"
const outline_format: cstr = c"Outline size: %i px"
const window_title: cstr = c"raylib [shaders] example - texture outline"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let texture = rl.LoadTexture(texture_path)
    defer rl.UnloadTexture(texture)

    let shader = rl.LoadShader(zero[cstr?](), rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    var outline_size: f32 = 2.0
    var outline_color = array[f32, 4](1.0, 0.0, 0.0, 1.0)
    var texture_size = array[f32, 2](cast[f32](texture.width), cast[f32](texture.height))

    let outline_size_loc = rl.GetShaderLocation(shader, outline_size_uniform_name)
    let outline_color_loc = rl.GetShaderLocation(shader, outline_color_uniform_name)
    let texture_size_loc = rl.GetShaderLocation(shader, texture_size_uniform_name)

    rl.SetShaderValue(shader, outline_size_loc, raw(addr(outline_size)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
    rl.SetShaderValue(shader, outline_color_loc, raw(addr(outline_color[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)
    rl.SetShaderValue(shader, texture_size_loc, raw(addr(texture_size[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        outline_size += rl.GetMouseWheelMove()
        if outline_size < 1.0:
            outline_size = 1.0

        rl.SetShaderValue(shader, outline_size_loc, raw(addr(outline_size)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginShaderMode(shader)
        rl.DrawTexture(texture, rl.GetScreenWidth() / 2 - texture.width / 2, -30, rl.WHITE)
        rl.EndShaderMode()

        rl.DrawText(title_text, 10, 10, 20, rl.GRAY)
        rl.DrawText(help_text, 10, 72, 20, rl.GRAY)
        rl.DrawText(rl.TextFormat(outline_format, cast[i32](outline_size)), 10, 120, 20, rl.MAROON)
        rl.DrawFPS(710, 10)

    return 0
