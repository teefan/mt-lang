module examples.raylib.core.core_text_file_loading

import std.c.raylib as rl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const font_size: i32 = 20
const wrap_width: i32 = screen_width - 20
const text_top: i32 = 25 + font_size
const line_gap: i32 = 10
const window_title: cstr = c"raylib [core] example - text file loading"
const file_name: cstr = c"../resources/text_file.txt"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var cam = rl.Camera2D(
        offset = rl.Vector2(x = 0.0, y = 0.0),
        target = rl.Vector2(x = 0.0, y = 0.0),
        rotation = 0.0,
        zoom = 1.0,
    )

    let text = rl.LoadFileText(file_name)
    var line_count = 0
    var lines: ptr[ptr[char]]
    unsafe:
        lines = rl.LoadTextLines(cstr<-text, ptr_of(ref_of(line_count)))

    let default_font = rl.GetFontDefault()
    let space_char = char<-32
    let null_char = char<-0
    let newline_char = char<-10

    var wrap_index = 0
    while wrap_index < line_count:
        unsafe:
            var line = read(lines + wrap_index)
            let line_length = i32<-rl.TextLength(cstr<-line)
            var j = 0
            var last_space = 0
            var last_wrap_start = 0

            while j <= line_length:
                let current = line[j]
                if current == space_char or current == null_char:
                    let before = current
                    line[j] = null_char

                    if rl.MeasureText(cstr<-(line + last_wrap_start), font_size) > wrap_width:
                        line[last_space] = newline_char
                        last_wrap_start = last_space + 1

                    if before != null_char:
                        line[j] = space_char

                    last_space = j

                j += 1

        wrap_index += 1

    var text_height = 0
    var line_index = 0
    while line_index < line_count:
        unsafe:
            let line = cstr<-read(lines + line_index)
            let measured_text = if rl.TextIsEqual(line, c"") then c" " else line
            let size = rl.MeasureTextEx(default_font, measured_text, f32<-font_size, 2.0)
            text_height += i32<-size.y + line_gap
        line_index += 1

    let scroll_range = if text_height > screen_height then text_height - screen_height else 1
    var scroll_bar = rl.Rectangle(
        x = f32<-screen_width - 5.0,
        y = f32<-text_top,
        width = 5.0,
        height = if text_height > screen_height then f32<-screen_height * 100.0 / f32<-scroll_range else f32<-(screen_height - text_top),
    )

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let scroll = rl.GetMouseWheelMove()
        cam.target.y -= scroll * f32<-font_size * 1.5

        if cam.target.y < 0.0:
            cam.target.y = 0.0

        let max_target_y = if text_height > screen_height then f32<-(text_height - screen_height + text_top) else 0.0
        if cam.target.y > max_target_y:
            cam.target.y = max_target_y

        let scroll_ratio: f32 = if text_height > screen_height then rm.clamp((cam.target.y - f32<-text_top) / f32<-scroll_range, 0.0, 1.0) else 0.0
        scroll_bar.y = rm.lerp(f32<-text_top, f32<-screen_height - scroll_bar.height, scroll_ratio)

        rl.BeginDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode2D(cam)
        var draw_index = 0
        var draw_y = text_top
        while draw_index < line_count:
            unsafe:
                let line = cstr<-read(lines + draw_index)
                let measured_text = if rl.TextIsEqual(line, c"") then c" " else line
                let size = rl.MeasureTextEx(default_font, measured_text, f32<-font_size, 2.0)
                rl.DrawText(line, 10, draw_y, font_size, rl.RED)
                draw_y += i32<-size.y + line_gap
            draw_index += 1
        rl.EndMode2D()

        rl.DrawRectangle(0, 0, screen_width, text_top - 10, rl.BEIGE)
        rl.DrawText(rl.TextFormat(c"File: %s", file_name), 10, 10, font_size, rl.MAROON)
        rl.DrawRectangleRec(scroll_bar, rl.MAROON)

        rl.EndDrawing()

    rl.UnloadTextLines(lines, line_count)
    rl.UnloadFileText(text)

    return 0
