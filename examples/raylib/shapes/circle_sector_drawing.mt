import std.math as math
import std.raygui as gui
import std.raylib as rl
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - circle sector drawing")
    defer rl.close_window()

    let center = rl.Vector2(x = float<-(rl.get_screen_width() - 300) / 2.0, y = float<-rl.get_screen_height() / 2.0)
    var outer_radius: float = 180.0
    var start_angle: float = 0.0
    var end_angle: float = 180.0
    var segments: float = 10.0
    var min_segments: float = 4.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_line(500, 0, 500, rl.get_screen_height(), rl.fade(rl.LIGHTGRAY, 0.6))
        rl.draw_rectangle(500, 0, rl.get_screen_width() - 500, rl.get_screen_height(), rl.fade(rl.LIGHTGRAY, 0.3))

        rl.draw_circle_sector(center, outer_radius, start_angle, end_angle, int<-segments, rl.fade(rl.MAROON, 0.3))
        rl.draw_circle_sector_lines(center, outer_radius, start_angle, end_angle, int<-segments, rl.fade(rl.MAROON, 0.6))

        gui.slider_bar(
            rl.Rectangle(x = 600.0, y = 40.0, width = 120.0, height = 20.0),
            "StartAngle",
            text.cstr_as_str(rl.text_format("%.2f", start_angle)),
            start_angle,
            0.0,
            720.0,
        )
        gui.slider_bar(
            rl.Rectangle(x = 600.0, y = 70.0, width = 120.0, height = 20.0),
            "EndAngle",
            text.cstr_as_str(rl.text_format("%.2f", end_angle)),
            end_angle,
            0.0,
            720.0,
        )
        gui.slider_bar(
            rl.Rectangle(x = 600.0, y = 140.0, width = 120.0, height = 20.0),
            "Radius",
            text.cstr_as_str(rl.text_format("%.2f", outer_radius)),
            outer_radius,
            0.0,
            200.0,
        )
        gui.slider_bar(
            rl.Rectangle(x = 600.0, y = 170.0, width = 120.0, height = 20.0),
            "Segments",
            text.cstr_as_str(rl.text_format("%.2f", segments)),
            segments,
            0.0,
            100.0,
        )

        min_segments = float<-math.ceil(double<-((end_angle - start_angle) / 90.0))
        if min_segments < 1.0:
            min_segments = 1.0
        let mode_text = if segments >= min_segments: "MANUAL" else: "AUTO"
        let mode_color = if segments >= min_segments: rl.MAROON else: rl.DARKGRAY
        rl.draw_text(f"MODE: #{mode_text}", 600, 200, 10, mode_color)

        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
