module examples.raylib.shapes.shapes_basic_shapes

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - basic shapes"
const help_text: cstr = c"some basic shapes available on raylib"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var rotation: f32 = 0.0
    let circle_x = screen_width / 5
    let circle_center_x: f32 = circle_x
    let rect_center_x = screen_width / 4 * 2
    let poly_center_x: f32 = screen_width * 3 / 4

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rotation += 0.2

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawText(help_text, 20, 20, 20, rl.DARKGRAY)

        rl.DrawCircle(circle_x, 120, 35.0, rl.DARKBLUE)
        rl.DrawCircleGradient(rl.Vector2(x = circle_center_x, y = 220.0), 60.0, rl.GREEN, rl.SKYBLUE)
        rl.DrawCircleLines(circle_x, 340, 80.0, rl.DARKBLUE)
        rl.DrawEllipse(circle_x, 120, 25.0, 20.0, rl.YELLOW)
        rl.DrawEllipseLines(circle_x, 120, 30.0, 25.0, rl.YELLOW)

        rl.DrawRectangle(rect_center_x - 60, 100, 120, 60, rl.RED)
        rl.DrawRectangleGradientH(rect_center_x - 90, 170, 180, 130, rl.MAROON, rl.GOLD)
        rl.DrawRectangleLines(rect_center_x - 40, 320, 80, 60, rl.ORANGE)

        rl.DrawTriangle(
            rl.Vector2(x = poly_center_x, y = 80.0),
            rl.Vector2(x = poly_center_x - 60.0, y = 150.0),
            rl.Vector2(x = poly_center_x + 60.0, y = 150.0),
            rl.VIOLET,
        )
        rl.DrawTriangleLines(
            rl.Vector2(x = poly_center_x, y = 160.0),
            rl.Vector2(x = poly_center_x - 20.0, y = 230.0),
            rl.Vector2(x = poly_center_x + 20.0, y = 230.0),
            rl.DARKBLUE,
        )

        let poly_center = rl.Vector2(x = poly_center_x, y = 330.0)
        rl.DrawPoly(poly_center, 6, 80.0, rotation, rl.BROWN)
        rl.DrawPolyLines(poly_center, 6, 90.0, rotation, rl.BROWN)
        rl.DrawPolyLinesEx(poly_center, 6, 85.0, rotation, 6.0, rl.BEIGE)

        rl.DrawLine(18, 42, screen_width - 18, 42, rl.BLACK)

    return 0
