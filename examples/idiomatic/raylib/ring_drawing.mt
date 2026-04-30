module examples.idiomatic.raylib.ring_drawing

import std.raygui as gui
import std.raylib as rl
import std.raylib.math as math

const screen_width: i32 = 800
const screen_height: i32 = 450

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Ring Drawing")
    defer rl.close_window()

    let center = rl.Vector2(x = (f32<-screen_width - 300.0) / 2.0, y = f32<-screen_height / 2.0)
    var inner_radius: f32 = 80.0
    var outer_radius: f32 = 190.0
    var start_angle: f32 = 0.0
    var end_angle: f32 = 360.0
    var segments: f32 = 0.0
    var draw_ring = true
    var draw_ring_lines = false
    var draw_circle_lines = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_line(500, 0, 500, rl.get_screen_height(), rl.fade(rl.LIGHTGRAY, 0.6))
        rl.draw_rectangle(500, 0, rl.get_screen_width() - 500, rl.get_screen_height(), rl.fade(rl.LIGHTGRAY, 0.3))

        if draw_ring:
            rl.draw_ring(center, inner_radius, outer_radius, start_angle, end_angle, i32<-segments, rl.fade(rl.MAROON, 0.3))
        if draw_ring_lines:
            rl.draw_ring_lines(center, inner_radius, outer_radius, start_angle, end_angle, i32<-segments, rl.fade(rl.BLACK, 0.4))
        if draw_circle_lines:
            rl.draw_circle_sector_lines(center, outer_radius, start_angle, end_angle, i32<-segments, rl.fade(rl.BLACK, 0.4))

        gui.slider_bar(rl.Rectangle(x = 600.0, y = 40.0, width = 120.0, height = 20.0), "StartAngle", rl.text_format_f32("%.2f", start_angle), inout start_angle, -450.0, 450.0)
        gui.slider_bar(rl.Rectangle(x = 600.0, y = 70.0, width = 120.0, height = 20.0), "EndAngle", rl.text_format_f32("%.2f", end_angle), inout end_angle, -450.0, 450.0)
        gui.slider_bar(rl.Rectangle(x = 600.0, y = 140.0, width = 120.0, height = 20.0), "InnerRadius", rl.text_format_f32("%.2f", inner_radius), inout inner_radius, 0.0, 100.0)
        gui.slider_bar(rl.Rectangle(x = 600.0, y = 170.0, width = 120.0, height = 20.0), "OuterRadius", rl.text_format_f32("%.2f", outer_radius), inout outer_radius, 0.0, 200.0)
        gui.slider_bar(rl.Rectangle(x = 600.0, y = 240.0, width = 120.0, height = 20.0), "Segments", rl.text_format_f32("%.2f", segments), inout segments, 0.0, 100.0)
        gui.check_box(rl.Rectangle(x = 600.0, y = 320.0, width = 20.0, height = 20.0), "Draw Ring", inout draw_ring)
        gui.check_box(rl.Rectangle(x = 600.0, y = 350.0, width = 20.0, height = 20.0), "Draw RingLines", inout draw_ring_lines)
        gui.check_box(rl.Rectangle(x = 600.0, y = 380.0, width = 20.0, height = 20.0), "Draw CircleLines", inout draw_circle_lines)

        let min_segments = math.ceil((end_angle - start_angle) / 90.0)
        rl.draw_text(
            rl.text_format_cstr("MODE: %s", if segments >= min_segments then "MANUAL" else "AUTO"),
            600,
            270,
            10,
            if segments >= min_segments then rl.MAROON else rl.DARKGRAY,
        )
        rl.draw_fps(10, 10)

    return 0
