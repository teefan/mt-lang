module examples.raylib.shaders.shaders_palette_switch

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const max_palettes: i32 = 3
const colors_per_palette: i32 = 8
const palette_value_count: i32 = 24
const shader_path_format: cstr = c"../resources/shaders/glsl%i/palette_switch.fs"
const palette_uniform_name: cstr = c"palette"
const selector_text: cstr = c"< >"
const current_palette_text: cstr = c"CURRENT PALETTE:"
const window_title: cstr = c"raylib [shaders] example - palette switch"

def set_palette_uniform(shader: rl.Shader, location: i32, palette: array[i32, palette_value_count]) -> void:
    var palette_data = palette
    rl.SetShaderValueV(
        shader,
        location,
        ptr_of(ref_of(palette_data[0])),
        rl.ShaderUniformDataType.SHADER_UNIFORM_IVEC3,
        colors_per_palette,
    )

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let shader = rl.LoadShader(zero[cstr?](), rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    let palette_location = rl.GetShaderLocation(shader, palette_uniform_name)
    let line_height = screen_height / colors_per_palette

    let palettes = array[array[i32, palette_value_count], max_palettes](
        array[i32, palette_value_count](
            0, 0, 0,
            255, 0, 0,
            0, 255, 0,
            0, 0, 255,
            0, 255, 255,
            255, 0, 255,
            255, 255, 0,
            255, 255, 255,
        ),
        array[i32, palette_value_count](
            4, 12, 6,
            17, 35, 24,
            30, 58, 41,
            48, 93, 66,
            77, 128, 97,
            137, 162, 87,
            190, 220, 127,
            238, 255, 204,
        ),
        array[i32, palette_value_count](
            21, 25, 26,
            138, 76, 88,
            217, 98, 117,
            230, 184, 193,
            69, 107, 115,
            75, 151, 166,
            165, 189, 194,
            255, 245, 247,
        ),
    )

    let palette_texts = array[cstr, max_palettes](
        c"3-BIT RGB",
        c"AMMO-8 (GameBoy-like)",
        c"RKBV (2-strip film)",
    )

    var current_palette = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            current_palette += 1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
            current_palette -= 1

        if current_palette >= max_palettes:
            current_palette = 0
        elif current_palette < 0:
            current_palette = max_palettes - 1

        set_palette_uniform(shader, palette_location, palettes[current_palette])

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginShaderMode(shader)

        var palette_index = 0
        while palette_index < colors_per_palette:
            rl.DrawRectangle(
                0,
                line_height * palette_index,
                rl.GetScreenWidth(),
                line_height,
                rl.Color(r = palette_index, g = palette_index, b = palette_index, a = 255),
            )
            palette_index += 1

        rl.EndShaderMode()

        rl.DrawText(selector_text, 10, 10, 30, rl.DARKBLUE)
        rl.DrawText(current_palette_text, 60, 15, 20, rl.RAYWHITE)
        rl.DrawText(palette_texts[current_palette], 300, 15, 20, rl.RED)
        rl.DrawFPS(700, 15)

    return 0