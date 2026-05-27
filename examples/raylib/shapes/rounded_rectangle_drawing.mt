import std.raygui as gui
import std.raylib as rl
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - rounded rectangle drawing")
    defer rl.close_window()

    var roundness: float = 0.2
    var rect_width: float = 200.0
    var rect_height: float = 100.0
    var segments: float = 0.0
    var line_thick: float = 1.0
    var draw_rect = false
    var draw_rounded_rect = true
    var draw_rounded_lines = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let rec = rl.Rectangle(
            x = (float<-rl.get_screen_width() - rect_width - 250.0) / 2.0,
            y = (float<-rl.get_screen_height() - rect_height) / 2.0,
            width = rect_width,
            height = rect_height,
        )

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_line(560, 0, 560, rl.get_screen_height(), rl.fade(rl.LIGHTGRAY, 0.6))
        rl.draw_rectangle(560, 0, rl.get_screen_width() - 500, rl.get_screen_height(), rl.fade(rl.LIGHTGRAY, 0.3))

        if draw_rect:
            rl.draw_rectangle_rec(rec, rl.fade(rl.GOLD, 0.6))
        if draw_rounded_rect:
            rl.draw_rectangle_rounded(rec, roundness, int<-segments, rl.fade(rl.MAROON, 0.2))
        if draw_rounded_lines:
            rl.draw_rectangle_rounded_lines_ex(rec, roundness, int<-segments, line_thick, rl.fade(rl.MAROON, 0.4))

        gui.slider_bar(rl.Rectangle(x = 640.0, y = 40.0, width = 105.0, height = 20.0), "Width", text.cstr_as_str(rl.text_format("%.2f", rect_width)), rect_width, 0.0, float<-rl.get_screen_width() - 300.0)
        gui.slider_bar(rl.Rectangle(x = 640.0, y = 70.0, width = 105.0, height = 20.0), "Height", text.cstr_as_str(rl.text_format("%.2f", rect_height)), rect_height, 0.0, float<-rl.get_screen_height() - 50.0)
        gui.slider_bar(rl.Rectangle(x = 640.0, y = 140.0, width = 105.0, height = 20.0), "Roundness", text.cstr_as_str(rl.text_format("%.2f", roundness)), roundness, 0.0, 1.0)
        gui.slider_bar(rl.Rectangle(x = 640.0, y = 170.0, width = 105.0, height = 20.0), "Thickness", text.cstr_as_str(rl.text_format("%.2f", line_thick)), line_thick, 0.0, 20.0)
        gui.slider_bar(rl.Rectangle(x = 640.0, y = 240.0, width = 105.0, height = 20.0), "Segments", text.cstr_as_str(rl.text_format("%.2f", segments)), segments, 0.0, 60.0)

        gui.check_box(rl.Rectangle(x = 640.0, y = 320.0, width = 20.0, height = 20.0), "DrawRoundedRect", draw_rounded_rect)
        gui.check_box(rl.Rectangle(x = 640.0, y = 350.0, width = 20.0, height = 20.0), "DrawRoundedLines", draw_rounded_lines)
        gui.check_box(rl.Rectangle(x = 640.0, y = 380.0, width = 20.0, height = 20.0), "DrawRect", draw_rect)

        let mode_text = if segments >= 4.0: "MANUAL" else: "AUTO"
        let mode_color = if segments >= 4.0: rl.MAROON else: rl.DARKGRAY
        rl.draw_text(f"MODE: #{mode_text}", 640, 280, 10, mode_color)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
