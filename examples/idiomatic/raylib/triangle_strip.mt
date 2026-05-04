module examples.idiomatic.raylib.triangle_strip

import std.raygui as gui
import std.raylib as rl
import std.raylib.math as math

const screen_width: i32 = 800
const screen_height: i32 = 450


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Triangle Strip")
    defer rl.close_window()

    var points = zero[array[rl.Vector2, 122]]()
    let center = rl.Vector2(x = f32<-screen_width / 2.0 - 125.0, y = f32<-screen_height / 2.0)
    var segments: f32 = 6.0
    var inside_radius: f32 = 100.0
    var outside_radius: f32 = 150.0
    var outline = true

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let point_count = i32<-segments
        let angle_step = 360.0 / f32<-point_count * math.deg2rad

        for index in 0..point_count:
            let point_index = index * 2
            let inner_angle = f32<-index * angle_step
            points[point_index] = rl.Vector2(
                x = center.x + math.cos(inner_angle) * inside_radius,
                y = center.y + math.sin(inner_angle) * inside_radius,
            )

            let outer_angle = inner_angle + angle_step / 2.0
            points[point_index + 1] = rl.Vector2(
                x = center.x + math.cos(outer_angle) * outside_radius,
                y = center.y + math.sin(outer_angle) * outside_radius,
            )

        points[point_count * 2] = points[0]
        points[point_count * 2 + 1] = points[1]

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        for index in 0..point_count:
            let a = points[index * 2]
            let b = points[index * 2 + 1]
            let c = points[index * 2 + 2]
            let d = points[index * 2 + 3]
            let inner_angle = f32<-index * angle_step

            rl.draw_triangle(c, b, a, rl.color_from_hsv(inner_angle * math.rad2deg, 1.0, 1.0))
            rl.draw_triangle(d, b, c, rl.color_from_hsv((inner_angle + angle_step / 2.0) * math.rad2deg, 1.0, 1.0))

            if outline:
                rl.draw_triangle_lines(a, b, c, rl.BLACK)
                rl.draw_triangle_lines(c, b, d, rl.BLACK)

        rl.draw_line(580, 0, 580, rl.get_screen_height(), rl.Color(r = 218, g = 218, b = 218, a = 255))
        rl.draw_rectangle(580, 0, rl.get_screen_width(), rl.get_screen_height(), rl.Color(r = 232, g = 232, b = 232, a = 255))
        gui.slider_bar(rl.Rectangle(x = 640.0, y = 40.0, width = 120.0, height = 20.0), "Segments", rl.text_format_f32("%.0f", segments), inout segments, 6.0, 60.0)
        gui.check_box(rl.Rectangle(x = 640.0, y = 70.0, width = 20.0, height = 20.0), "Outline", inout outline)
        rl.draw_fps(10, 10)

    return 0
