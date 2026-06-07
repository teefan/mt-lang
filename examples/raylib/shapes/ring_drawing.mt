import std.math as math
import std.raygui as gui
import std.raylib as rl
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - ring drawing")
    defer rl.close_window()

    let center = rl.Vector2(x = float<-(rl.get_screen_width() - 300) / 2.0, y = float<-rl.get_screen_height() / 2.0)
    var inner_radius: float = 80.0
    var outer_radius: float = 190.0
    var start_angle: float = 0.0
    var end_angle: float = 360.0
    var segments: float = 0.0
    var draw_ring = true
    var draw_ring_lines = false
    var draw_circle_lines = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_line(500, 0, 500, rl.get_screen_height(), rl.fade(rl.LIGHTGRAY, 0.6))
        rl.draw_rectangle(500, 0, rl.get_screen_width() - 500, rl.get_screen_height(), rl.fade(rl.LIGHTGRAY, 0.3))

        if draw_ring:
            rl.draw_ring(
                center,
                inner_radius,
                outer_radius,
                start_angle,
                end_angle,
                int<-segments,
                rl.fade(rl.MAROON, 0.3)
            )
        if draw_ring_lines:
            rl.draw_ring_lines(
                center,
                inner_radius,
                outer_radius,
                start_angle,
                end_angle,
                int<-segments,
                rl.fade(rl.BLACK, 0.4)
            )
        if draw_circle_lines:
            rl.draw_circle_sector_lines(
                center,
                outer_radius,
                start_angle,
                end_angle,
                int<-segments,
                rl.fade(rl.BLACK, 0.4)
            )

        gui.slider_bar(
            rl.Rectangle(x = 600.0, y = 40.0, width = 120.0, height = 20.0),
            "StartAngle",
            text.cstr_as_str(rl.text_format("%.2f", start_angle)),
            start_angle,
            -450.0,
            450.0
        )
        gui.slider_bar(
            rl.Rectangle(x = 600.0, y = 70.0, width = 120.0, height = 20.0),
            "EndAngle",
            text.cstr_as_str(rl.text_format("%.2f", end_angle)),
            end_angle,
            -450.0,
            450.0
        )
        gui.slider_bar(
            rl.Rectangle(x = 600.0, y = 140.0, width = 120.0, height = 20.0),
            "InnerRadius",
            text.cstr_as_str(rl.text_format("%.2f", inner_radius)),
            inner_radius,
            0.0,
            100.0
        )
        gui.slider_bar(
            rl.Rectangle(x = 600.0, y = 170.0, width = 120.0, height = 20.0),
            "OuterRadius",
            text.cstr_as_str(rl.text_format("%.2f", outer_radius)),
            outer_radius,
            0.0,
            200.0
        )
        gui.slider_bar(
            rl.Rectangle(x = 600.0, y = 240.0, width = 120.0, height = 20.0),
            "Segments",
            text.cstr_as_str(rl.text_format("%.2f", segments)),
            segments,
            0.0,
            100.0
        )

        gui.check_box(rl.Rectangle(x = 600.0, y = 320.0, width = 20.0, height = 20.0), "Draw Ring", draw_ring)
        gui.check_box(
            rl.Rectangle(x = 600.0, y = 350.0, width = 20.0, height = 20.0),
            "Draw RingLines",
            draw_ring_lines
        )
        gui.check_box(
            rl.Rectangle(x = 600.0, y = 380.0, width = 20.0, height = 20.0),
            "Draw CircleLines",
            draw_circle_lines
        )

        var min_segments: float = float<-math.ceil(double<-((end_angle - start_angle) / 90.0))
        if min_segments < 1.0:
            min_segments = 1.0
        let mode_text = if segments >= min_segments: "MANUAL" else: "AUTO"
        let mode_color = if segments >= min_segments: rl.MAROON else: rl.DARKGRAY
        rl.draw_text(f"MODE: #{mode_text}", 600, 270, 10, mode_color)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
