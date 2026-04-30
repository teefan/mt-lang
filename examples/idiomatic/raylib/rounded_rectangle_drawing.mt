module examples.idiomatic.raylib.rounded_rectangle_drawing

import std.raygui as gui
import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Rounded Rectangle Drawing")
    defer rl.close_window()

    var roundness: f32 = 0.2
    var width: f32 = 200.0
    var height: f32 = 100.0
    var segments: f32 = 0.0
    var line_thick: f32 = 1.0
    var draw_rect = false
    var draw_rounded_rect = true
    var draw_rounded_lines = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let rec = rl.Rectangle(
            x = (f32<-rl.get_screen_width() - width - 250.0) / 2.0,
            y = (f32<-rl.get_screen_height() - height) / 2.0,
            width = width,
            height = height,
        )

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_line(560, 0, 560, rl.get_screen_height(), rl.fade(rl.LIGHTGRAY, 0.6))
        rl.draw_rectangle(560, 0, rl.get_screen_width() - 500, rl.get_screen_height(), rl.fade(rl.LIGHTGRAY, 0.3))

        if draw_rect:
            rl.draw_rectangle_rec(rec, rl.fade(rl.GOLD, 0.6))
        if draw_rounded_rect:
            rl.draw_rectangle_rounded(rec, roundness, i32<-segments, rl.fade(rl.MAROON, 0.2))
        if draw_rounded_lines:
            rl.draw_rectangle_rounded_lines_ex(rec, roundness, i32<-segments, line_thick, rl.fade(rl.MAROON, 0.4))

        gui.slider_bar(rl.Rectangle(x = 640.0, y = 40.0, width = 105.0, height = 20.0), "Width", rl.text_format_f32("%.2f", width), inout width, 0.0, f32<-rl.get_screen_width() - 300.0)
        gui.slider_bar(rl.Rectangle(x = 640.0, y = 70.0, width = 105.0, height = 20.0), "Height", rl.text_format_f32("%.2f", height), inout height, 0.0, f32<-rl.get_screen_height() - 50.0)
        gui.slider_bar(rl.Rectangle(x = 640.0, y = 140.0, width = 105.0, height = 20.0), "Roundness", rl.text_format_f32("%.2f", roundness), inout roundness, 0.0, 1.0)
        gui.slider_bar(rl.Rectangle(x = 640.0, y = 170.0, width = 105.0, height = 20.0), "Thickness", rl.text_format_f32("%.2f", line_thick), inout line_thick, 0.0, 20.0)
        gui.slider_bar(rl.Rectangle(x = 640.0, y = 240.0, width = 105.0, height = 20.0), "Segments", rl.text_format_f32("%.2f", segments), inout segments, 0.0, 60.0)
        gui.check_box(rl.Rectangle(x = 640.0, y = 320.0, width = 20.0, height = 20.0), "DrawRoundedRect", inout draw_rounded_rect)
        gui.check_box(rl.Rectangle(x = 640.0, y = 350.0, width = 20.0, height = 20.0), "DrawRoundedLines", inout draw_rounded_lines)
        gui.check_box(rl.Rectangle(x = 640.0, y = 380.0, width = 20.0, height = 20.0), "DrawRect", inout draw_rect)

        rl.draw_text(
            rl.text_format_cstr("MODE: %s", if segments >= 4.0 then "MANUAL" else "AUTO"),
            640,
            280,
            10,
            if segments >= 4.0 then rl.MAROON else rl.DARKGRAY,
        )
        rl.draw_fps(10, 10)

    return 0
