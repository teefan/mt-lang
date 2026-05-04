module examples.raylib.text.text_words_alignment

import std.c.raylib as rl
import std.raylib.math as rm

enum TextAlignment: i32
    TEXT_ALIGN_LEFT = 0
    TEXT_ALIGN_TOP = 0
    TEXT_ALIGN_CENTRE = 1
    TEXT_ALIGN_MIDDLE = 1
    TEXT_ALIGN_RIGHT = 2
    TEXT_ALIGN_BOTTOM = 2

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [text] example - words alignment"
const words_source: cstr = c"raylib is a simple and easy-to-use library to enjoy videogames programming"
const help_text: cstr = c"Use Arrow Keys to change the text alignment"
const align_format: cstr = c"Alignment: Horizontal = %s, Vertical = %s"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var text_container_rect = rl.Rectangle(
        x = f32<-screen_width / 2.0 - f32<-screen_width / 4.0,
        y = f32<-screen_height / 2.0 - f32<-screen_height / 3.0,
        width = f32<-screen_width / 2.0,
        height = f32<-screen_height * 2.0 / 3.0,
    )

    let text_align_name_h = array[cstr, 3](c"Left", c"Centre", c"Right")
    let text_align_name_v = array[cstr, 3](c"Top", c"Middle", c"Bottom")

    var word_index = 0
    var word_count = 0
    let words = rl.TextSplit(words_source, char<-32, ptr_of(word_count))

    let font_size = 40
    let font = rl.GetFontDefault()

    var h_align = TextAlignment.TEXT_ALIGN_CENTRE
    var v_align = TextAlignment.TEXT_ALIGN_MIDDLE

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
            if h_align > TextAlignment.TEXT_ALIGN_LEFT:
                h_align = TextAlignment<-(i32<-h_align - 1)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            h_align = TextAlignment<-(i32<-h_align + 1)
            if h_align > TextAlignment.TEXT_ALIGN_RIGHT:
                h_align = TextAlignment.TEXT_ALIGN_RIGHT

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_UP):
            if v_align > TextAlignment.TEXT_ALIGN_TOP:
                v_align = TextAlignment<-(i32<-v_align - 1)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_DOWN):
            v_align = TextAlignment<-(i32<-v_align + 1)
            if v_align > TextAlignment.TEXT_ALIGN_BOTTOM:
                v_align = TextAlignment.TEXT_ALIGN_BOTTOM

        if word_count > 0:
            word_index = i32<-rl.GetTime() % word_count
        else:
            word_index = 0

        unsafe:
            let current_word = cstr<-read(words + word_index)
            let text_size = rl.MeasureTextEx(font, current_word, f32<-font_size, f32<-font_size * 0.1)
            let text_pos = rl.Vector2(
                x = text_container_rect.x + rm.lerp(0.0, text_container_rect.width - text_size.x, f32<-h_align * 0.5),
                y = text_container_rect.y + rm.lerp(0.0, text_container_rect.height - text_size.y, f32<-v_align * 0.5),
            )

            rl.BeginDrawing()
            defer rl.EndDrawing()

            rl.ClearBackground(rl.DARKBLUE)
            rl.DrawText(help_text, 20, 20, 20, rl.LIGHTGRAY)
            rl.DrawText(
                rl.TextFormat(align_format, text_align_name_h[i32<-h_align], text_align_name_v[i32<-v_align]),
                20,
                40,
                20,
                rl.LIGHTGRAY,
            )
            rl.DrawRectangleRec(text_container_rect, rl.BLUE)
            rl.DrawTextEx(font, current_word, text_pos, f32<-font_size, f32<-font_size * 0.1, rl.RAYWHITE)

    return 0
