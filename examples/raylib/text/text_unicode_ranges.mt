module examples.raylib.text.text_unicode_ranges

import std.c.raylib as rl
import std.mem.heap as heap

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [text] example - unicode ranges"
const font_path: cstr = c"resources/NotoSansTC-Regular.ttf"
const add_codepoints_text: cstr = c"ADD CODEPOINTS: [1][2][3][4]"
const english_text: cstr = c"> English: Hello World!"
const spanish_text: cstr = c"> Español: Hola mundo!"
const greek_text: cstr = c"> Ελληνικά: Γειά σου κόσμε!"
const russian_text: cstr = c"> Русский: Привет мир!"
const chinese_text: cstr = c"> 中文: 你好世界!"
const japanese_text: cstr = c"> 日本語: こんにちは世界!"
const atlas_size_format: cstr = c"ATLAS SIZE: %ix%i px (x%02.2f)"
const glyph_count_format: cstr = c"CODEPOINTS GLYPHS LOADED: %i"
const attribution_text: cstr = c"Font: Noto Sans TC. License: SIL Open Font License 1.1"

def add_codepoint_range(font: rl.Font, font_path: cstr, start: i32, stop: i32) -> rl.Font:
    let range_size = stop - start + 1
    let current_range_size = font.glyphCount
    let updated_codepoint_count = current_range_size + range_size
    let updated_codepoints = heap.must_alloc_zeroed[i32](cast[usize](updated_codepoint_count))
    defer heap.release(updated_codepoints)

    unsafe:
        for index in range(0, current_range_size):
            deref(updated_codepoints + index) = font.glyphs[index].value

        for index in range(current_range_size, updated_codepoint_count):
            deref(updated_codepoints + index) = start + (index - current_range_size)

    rl.UnloadFont(font)
    return rl.LoadFontEx(font_path, 32, updated_codepoints, updated_codepoint_count)

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var font = rl.LoadFont(font_path)
    defer rl.UnloadFont(font)
    rl.SetTextureFilter(font.texture, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)

    var unicode_range = 0
    var prev_unicode_range = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if unicode_range != prev_unicode_range:
            rl.UnloadFont(font)
            font = rl.LoadFont(font_path)

            if unicode_range >= 1:
                font = add_codepoint_range(font, font_path, 0x00c0, 0x017f)
                font = add_codepoint_range(font, font_path, 0x0180, 0x024f)
            if unicode_range >= 2:
                font = add_codepoint_range(font, font_path, 0x0370, 0x03ff)
                font = add_codepoint_range(font, font_path, 0x1f00, 0x1fff)
            if unicode_range >= 3:
                font = add_codepoint_range(font, font_path, 0x0400, 0x04ff)
                font = add_codepoint_range(font, font_path, 0x0500, 0x052f)
                font = add_codepoint_range(font, font_path, 0x2de0, 0x2dff)
                font = add_codepoint_range(font, font_path, 0xa640, 0xa69f)
            if unicode_range >= 4:
                font = add_codepoint_range(font, font_path, 0x4e00, 0x9fff)
                font = add_codepoint_range(font, font_path, 0x3400, 0x4dbf)
                font = add_codepoint_range(font, font_path, 0x3000, 0x303f)
                font = add_codepoint_range(font, font_path, 0x3040, 0x309f)
                font = add_codepoint_range(font, font_path, 0x30a0, 0x30ff)
                font = add_codepoint_range(font, font_path, 0x31f0, 0x31ff)
                font = add_codepoint_range(font, font_path, 0xff00, 0xffef)
                font = add_codepoint_range(font, font_path, 0xac00, 0xd7af)
                font = add_codepoint_range(font, font_path, 0x1100, 0x11ff)

            prev_unicode_range = unicode_range
            rl.SetTextureFilter(font.texture, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_ZERO):
            unicode_range = 0
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_ONE):
            unicode_range = 1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_TWO):
            unicode_range = 2
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_THREE):
            unicode_range = 3
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_FOUR):
            unicode_range = 4

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawText(add_codepoints_text, 20, 20, 20, rl.MAROON)

        rl.DrawTextEx(font, english_text, rl.Vector2(x = 50.0, y = 70.0), 32.0, 1.0, rl.DARKGRAY)
        rl.DrawTextEx(font, spanish_text, rl.Vector2(x = 50.0, y = 120.0), 32.0, 1.0, rl.DARKGRAY)
        rl.DrawTextEx(font, greek_text, rl.Vector2(x = 50.0, y = 170.0), 32.0, 1.0, rl.DARKGRAY)
        rl.DrawTextEx(font, russian_text, rl.Vector2(x = 50.0, y = 220.0), 32.0, 0.0, rl.DARKGRAY)
        rl.DrawTextEx(font, chinese_text, rl.Vector2(x = 50.0, y = 270.0), 32.0, 1.0, rl.DARKGRAY)
        rl.DrawTextEx(font, japanese_text, rl.Vector2(x = 50.0, y = 320.0), 32.0, 1.0, rl.DARKGRAY)

        let atlas_scale = 380.0 / cast[f32](font.texture.width)
        rl.DrawRectangleRec(
            rl.Rectangle(
                x = 400.0,
                y = 16.0,
                width = cast[f32](font.texture.width) * atlas_scale,
                height = cast[f32](font.texture.height) * atlas_scale,
            ),
            rl.BLACK,
        )
        rl.DrawTexturePro(
            font.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = cast[f32](font.texture.width), height = cast[f32](font.texture.height)),
            rl.Rectangle(x = 400.0, y = 16.0, width = cast[f32](font.texture.width) * atlas_scale, height = cast[f32](font.texture.height) * atlas_scale),
            rl.Vector2(x = 0.0, y = 0.0),
            0.0,
            rl.WHITE,
        )
        rl.DrawRectangleLines(400, 16, 380, 380, rl.RED)

        rl.DrawText(rl.TextFormat(atlas_size_format, font.texture.width, font.texture.height, atlas_scale), 20, 380, 20, rl.BLUE)
        rl.DrawText(rl.TextFormat(glyph_count_format, font.glyphCount), 20, 410, 20, rl.LIME)
        rl.DrawText(attribution_text, screen_width - 300, screen_height - 20, 10, rl.GRAY)

    return 0
