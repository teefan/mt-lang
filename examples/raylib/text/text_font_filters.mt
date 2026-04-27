module examples.raylib.text.text_font_filters

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [text] example - font filters"
const font_path: cstr = c"resources/KAISG.ttf"
const msg: cstr = c"Loaded Font"
const info_size_text: cstr = c"Use mouse wheel to change font size"
const info_move_text: cstr = c"Use KEY_RIGHT and KEY_LEFT to move text"
const info_filter_text: cstr = c"Use 1, 2, 3 to change texture filter"
const info_drop_text: cstr = c"Drop a new TTF font for dynamic loading"
const font_size_format: cstr = c"Font size: %02.02f"
const text_size_format: cstr = c"Text size: [%02.02f, %02.02f]"
const filter_label_text: cstr = c"CURRENT TEXTURE FILTER:"
const point_text: cstr = c"POINT"
const bilinear_text: cstr = c"BILINEAR"
const trilinear_text: cstr = c"TRILINEAR"
const ttf_ext: cstr = c".ttf"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var font = rl.LoadFontEx(font_path, 96, zero[ptr[i32]](), 0)
    defer rl.UnloadFont(font)

    rl.GenTextureMipmaps(raw(addr(font.texture)))

    var font_size = cast[f32](font.baseSize)
    var font_position = rl.Vector2(x = 40.0, y = cast[f32](screen_height) / 2.0 - 80.0)
    var text_size = rl.Vector2(x = 0.0, y = 0.0)

    rl.SetTextureFilter(font.texture, rl.TextureFilter.TEXTURE_FILTER_POINT)
    var current_font_filter = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        font_size += rl.GetMouseWheelMove() * 4.0

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_ONE):
            rl.SetTextureFilter(font.texture, rl.TextureFilter.TEXTURE_FILTER_POINT)
            current_font_filter = 0
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_TWO):
            rl.SetTextureFilter(font.texture, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)
            current_font_filter = 1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_THREE):
            rl.SetTextureFilter(font.texture, rl.TextureFilter.TEXTURE_FILTER_TRILINEAR)
            current_font_filter = 2

        text_size = rl.MeasureTextEx(font, msg, font_size, 0.0)

        if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT):
            font_position.x -= 10.0
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT):
            font_position.x += 10.0

        if rl.IsFileDropped():
            let dropped_files = rl.LoadDroppedFiles()
            if dropped_files.count > 0:
                unsafe:
                    let dropped_path = cast[cstr](deref(dropped_files.paths))
                    if rl.IsFileExtension(dropped_path, ttf_ext):
                        rl.UnloadFont(font)
                        font = rl.LoadFontEx(dropped_path, cast[i32](font_size), zero[ptr[i32]](), 0)
            rl.UnloadDroppedFiles(dropped_files)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawText(info_size_text, 20, 20, 10, rl.GRAY)
        rl.DrawText(info_move_text, 20, 40, 10, rl.GRAY)
        rl.DrawText(info_filter_text, 20, 60, 10, rl.GRAY)
        rl.DrawText(info_drop_text, 20, 80, 10, rl.DARKGRAY)

        rl.DrawTextEx(font, msg, font_position, font_size, 0.0, rl.BLACK)

        rl.DrawRectangle(0, screen_height - 80, screen_width, 80, rl.LIGHTGRAY)
        rl.DrawText(rl.TextFormat(font_size_format, font_size), 20, screen_height - 50, 10, rl.DARKGRAY)
        rl.DrawText(rl.TextFormat(text_size_format, text_size.x, text_size.y), 20, screen_height - 30, 10, rl.DARKGRAY)
        rl.DrawText(filter_label_text, 250, 400, 20, rl.GRAY)

        if current_font_filter == 0:
            rl.DrawText(point_text, 570, 400, 20, rl.BLACK)
        elif current_font_filter == 1:
            rl.DrawText(bilinear_text, 570, 400, 20, rl.BLACK)
        elif current_font_filter == 2:
            rl.DrawText(trilinear_text, 570, 400, 20, rl.BLACK)

    return 0
