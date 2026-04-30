module examples.raylib.text.text_font_sdf

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [text] example - font sdf"
const msg: cstr = c"Signed Distance Fields"
const font_path: cstr = c"../resources/anonymous_pro_bold.ttf"
const shader_path: cstr = c"../resources/shaders/glsl330/sdf.fs"
const default_font_text: cstr = c"default font"
const sdf_text: cstr = c"SDF!"
const font_size_text: cstr = c"FONT SIZE: 16.0"
const render_size_format: cstr = c"RENDER SIZE: %02.02f"
const scale_help_text: cstr = c"Use MOUSE WHEEL to SCALE TEXT!"
const hold_space_text: cstr = c"HOLD SPACE to USE SDF FONT VERSION!"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var file_size = 0
    let file_data = rl.LoadFileData(font_path, ptr_of(ref_of(file_size)))
    defer rl.UnloadFileData(file_data)

    var font_default = zero[rl.Font]()
    font_default.baseSize = 16
    font_default.glyphCount = 95
    font_default.glyphs = rl.LoadFontData(file_data, file_size, 16, null, 95, rl.FontType.FONT_DEFAULT, ptr_of(ref_of(font_default.glyphCount)))
    var atlas = rl.GenImageFontAtlas(font_default.glyphs, ptr_of(ref_of(font_default.recs)), 95, 16, 4, 0)
    font_default.texture = rl.LoadTextureFromImage(atlas)
    rl.UnloadImage(atlas)
    defer rl.UnloadFont(font_default)

    var font_sdf = zero[rl.Font]()
    font_sdf.baseSize = 16
    font_sdf.glyphCount = 95
    font_sdf.glyphs = rl.LoadFontData(file_data, file_size, 16, null, 0, rl.FontType.FONT_SDF, ptr_of(ref_of(font_sdf.glyphCount)))
    atlas = rl.GenImageFontAtlas(font_sdf.glyphs, ptr_of(ref_of(font_sdf.recs)), 95, 16, 0, 1)
    font_sdf.texture = rl.LoadTextureFromImage(atlas)
    rl.UnloadImage(atlas)
    defer rl.UnloadFont(font_sdf)

    var shader = zero[rl.Shader]()
    shader = rl.LoadShader(null, shader_path)
    defer rl.UnloadShader(shader)

    rl.SetTextureFilter(font_sdf.texture, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)

    var font_position = rl.Vector2(x = 40.0, y = f32<-screen_height / 2.0 - 50.0)
    var text_size = rl.Vector2(x = 0.0, y = 0.0)
    var font_size: f32 = 16.0
    var current_font = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        font_size += rl.GetMouseWheelMove() * 8.0

        if font_size < 6.0:
            font_size = 6.0

        if rl.IsKeyDown(rl.KeyboardKey.KEY_SPACE):
            current_font = 1
        else:
            current_font = 0

        if current_font == 0:
            text_size = rl.MeasureTextEx(font_default, msg, font_size, 0.0)
        else:
            text_size = rl.MeasureTextEx(font_sdf, msg, font_size, 0.0)

        font_position.x = f32<-rl.GetScreenWidth() / 2.0 - text_size.x / 2.0
        font_position.y = f32<-rl.GetScreenHeight() / 2.0 - text_size.y / 2.0 + 80.0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        if current_font == 1:
            rl.BeginShaderMode(shader)
            rl.DrawTextEx(font_sdf, msg, font_position, font_size, 0.0, rl.BLACK)
            rl.EndShaderMode()

            rl.DrawTexture(font_sdf.texture, 10, 10, rl.BLACK)
        else:
            rl.DrawTextEx(font_default, msg, font_position, font_size, 0.0, rl.BLACK)
            rl.DrawTexture(font_default.texture, 10, 10, rl.BLACK)

        if current_font == 1:
            rl.DrawText(sdf_text, 320, 20, 80, rl.RED)
        else:
            rl.DrawText(default_font_text, 315, 40, 30, rl.GRAY)

        rl.DrawText(font_size_text, rl.GetScreenWidth() - 240, 20, 20, rl.DARKGRAY)
        rl.DrawText(rl.TextFormat(render_size_format, font_size), rl.GetScreenWidth() - 240, 50, 20, rl.DARKGRAY)
        rl.DrawText(scale_help_text, rl.GetScreenWidth() - 240, 90, 10, rl.DARKGRAY)
        rl.DrawText(hold_space_text, 340, rl.GetScreenHeight() - 30, 20, rl.MAROON)

    return 0
