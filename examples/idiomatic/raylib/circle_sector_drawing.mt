module examples.idiomatic.raylib.circle_sector_drawing

import std.raygui as gui
import std.raylib as rl
import std.raylib.math as math

const screen_width: i32 = 800
const screen_height: i32 = 450

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Circle Sector Drawing")
    defer rl.close_window()

    let center = rl.Vector2(x = (cast[f32](screen_width) - 300.0) / 2.0, y = cast[f32](screen_height) / 2.0)
    var outer_radius: f32 = 180.0
    var start_angle: f32 = 0.0
    var end_angle: f32 = 180.0
    var segments: f32 = 10.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_line(500, 0, 500, rl.get_screen_height(), rl.fade(rl.LIGHTGRAY, 0.6))
        rl.draw_rectangle(500, 0, rl.get_screen_width() - 500, rl.get_screen_height(), rl.fade(rl.LIGHTGRAY, 0.3))

        rl.draw_circle_sector(center, outer_radius, start_angle, end_angle, cast[i32](segments), rl.fade(rl.MAROON, 0.3))
        rl.draw_circle_sector_lines(center, outer_radius, start_angle, end_angle, cast[i32](segments), rl.fade(rl.MAROON, 0.6))

        gui.slider_bar(rl.Rectangle(x = 600.0, y = 40.0, width = 120.0, height = 20.0), "StartAngle", rl.text_format_f32("%.2f", start_angle), inout start_angle, 0.0, 720.0)
        gui.slider_bar(rl.Rectangle(x = 600.0, y = 70.0, width = 120.0, height = 20.0), "EndAngle", rl.text_format_f32("%.2f", end_angle), inout end_angle, 0.0, 720.0)
        gui.slider_bar(rl.Rectangle(x = 600.0, y = 140.0, width = 120.0, height = 20.0), "Radius", rl.text_format_f32("%.2f", outer_radius), inout outer_radius, 0.0, 200.0)
        gui.slider_bar(rl.Rectangle(x = 600.0, y = 170.0, width = 120.0, height = 20.0), "Segments", rl.text_format_f32("%.2f", segments), inout segments, 0.0, 100.0)

        let min_segments = math.ceil((end_angle - start_angle) / 90.0)
        rl.draw_text(
            rl.text_format_cstr("MODE: %s", if segments >= min_segments then "MANUAL" else "AUTO"),
            600,
            200,
            10,
            if segments >= min_segments then rl.MAROON else rl.DARKGRAY,
        )
        rl.draw_fps(10, 10)

    return 0
