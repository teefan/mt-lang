module examples.idiomatic.raylib.basic_shapes

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Basic Shapes")
    defer rl.close_window()

    var rotation: f32 = 0.0
    let circle_x = screen_width / 5
    let circle_center_x: f32 = circle_x
    let rect_center_x = screen_width / 4 * 2
    let poly_center_x: f32 = screen_width * 3 / 4

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rotation += 0.2

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("some basic shapes available on raylib", 20, 20, 20, rl.DARKGRAY)

        rl.draw_circle(circle_x, 120, 35.0, rl.DARKBLUE)
        rl.draw_circle_gradient(rl.Vector2(x = circle_center_x, y = 220.0), 60.0, rl.GREEN, rl.SKYBLUE)
        rl.draw_circle_lines(circle_x, 340, 80.0, rl.DARKBLUE)
        rl.draw_ellipse(circle_x, 120, 25.0, 20.0, rl.YELLOW)
        rl.draw_ellipse_lines(circle_x, 120, 30.0, 25.0, rl.YELLOW)

        rl.draw_rectangle(rect_center_x - 60, 100, 120, 60, rl.RED)
        rl.draw_rectangle_gradient_h(rect_center_x - 90, 170, 180, 130, rl.MAROON, rl.GOLD)
        rl.draw_rectangle_lines(rect_center_x - 40, 320, 80, 60, rl.ORANGE)

        rl.draw_triangle(
            rl.Vector2(x = poly_center_x, y = 80.0),
            rl.Vector2(x = poly_center_x - 60.0, y = 150.0),
            rl.Vector2(x = poly_center_x + 60.0, y = 150.0),
            rl.VIOLET,
        )
        rl.draw_triangle_lines(
            rl.Vector2(x = poly_center_x, y = 160.0),
            rl.Vector2(x = poly_center_x - 20.0, y = 230.0),
            rl.Vector2(x = poly_center_x + 20.0, y = 230.0),
            rl.DARKBLUE,
        )

        let poly_center = rl.Vector2(x = poly_center_x, y = 330.0)
        rl.draw_poly(poly_center, 6, 80.0, rotation, rl.BROWN)
        rl.draw_poly_lines(poly_center, 6, 90.0, rotation, rl.BROWN)
        rl.draw_poly_lines_ex(poly_center, 6, 85.0, rotation, 6.0, rl.BEIGE)

        rl.draw_line(18, 42, screen_width - 18, 42, rl.BLACK)

    return 0