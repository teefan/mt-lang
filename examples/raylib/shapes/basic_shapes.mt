import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - basic shapes")
    defer rl.close_window()

    var rotation: float = 0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rotation += 0.2

        rl.begin_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("some basic shapes available on raylib", 20, 20, 20, rl.DARKGRAY)

        rl.draw_circle(160, 120, 35.0, rl.DARKBLUE)
        rl.draw_circle_gradient(rl.Vector2(x = 160.0, y = 220.0), 60.0, rl.GREEN, rl.SKYBLUE)
        rl.draw_circle_lines(160, 340, 80.0, rl.DARKBLUE)
        rl.draw_ellipse(160, 120, 25.0, 20.0, rl.YELLOW)
        rl.draw_ellipse_lines(160, 120, 30.0, 25.0, rl.YELLOW)

        rl.draw_rectangle(340, 100, 120, 60, rl.RED)
        rl.draw_rectangle_gradient_h(310, 170, 180, 130, rl.MAROON, rl.GOLD)
        rl.draw_rectangle_lines(360, 320, 80, 60, rl.ORANGE)

        rl.draw_triangle(
            rl.Vector2(x = 600.0, y = 80.0),
            rl.Vector2(x = 540.0, y = 150.0),
            rl.Vector2(x = 660.0, y = 150.0),
            rl.VIOLET
        )
        rl.draw_triangle_lines(
            rl.Vector2(x = 600.0, y = 160.0),
            rl.Vector2(x = 580.0, y = 230.0),
            rl.Vector2(x = 620.0, y = 230.0),
            rl.DARKBLUE
        )

        rl.draw_poly(rl.Vector2(x = 600.0, y = 330.0), 6, 80.0, rotation, rl.BROWN)
        rl.draw_poly_lines(rl.Vector2(x = 600.0, y = 330.0), 6, 90.0, rotation, rl.BROWN)
        rl.draw_poly_lines_ex(rl.Vector2(x = 600.0, y = 330.0), 6, 85.0, rotation, 6.0, rl.BEIGE)

        rl.draw_line(18, 42, SCREEN_WIDTH - 18, 42, rl.BLACK)
        rl.end_drawing()

    return 0
