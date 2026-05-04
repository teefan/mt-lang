module examples.raylib.text.text_font_loading

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [text] example - font loading"
const msg: cstr = c"!#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHI\nJKLMNOPQRSTUVWXYZ[]^_`abcdefghijklmn\nopqrstuvwxyz{|}~¿ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓ\nÔÕÖ×ØÙÚÛÜÝÞßàáâãäåæçèéêëìíîïðñòóôõö÷\nøùúûüýþÿ"
const font_bm_path: cstr = c"../resources/pixantiqua.fnt"
const font_ttf_path: cstr = c"../resources/pixantiqua.ttf"
const hold_space_text: cstr = c"Hold SPACE to use TTF generated font"
const bm_text: cstr = c"Using BMFont (Angelcode) imported"
const ttf_text: cstr = c"Using TTF font generated"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let font_bm = rl.LoadFont(font_bm_path)
    defer rl.UnloadFont(font_bm)

    var font_ttf = zero[rl.Font]
    font_ttf = rl.LoadFontEx(font_ttf_path, 32, null, 250)
    defer rl.UnloadFont(font_ttf)

    rl.SetTextLineSpacing(16)

    var use_ttf = false

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        use_ttf = rl.IsKeyDown(rl.KeyboardKey.KEY_SPACE)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawText(hold_space_text, 20, 20, 20, rl.LIGHTGRAY)

        if not use_ttf:
            rl.DrawTextEx(font_bm, msg, rl.Vector2(x = 20.0, y = 100.0), f32<-font_bm.baseSize, 2.0, rl.MAROON)
            rl.DrawText(bm_text, 20, rl.GetScreenHeight() - 30, 20, rl.GRAY)
        else:
            rl.DrawTextEx(font_ttf, msg, rl.Vector2(x = 20.0, y = 100.0), f32<-font_ttf.baseSize, 2.0, rl.LIME)
            rl.DrawText(ttf_text, 20, rl.GetScreenHeight() - 30, 20, rl.GRAY)

    return 0
