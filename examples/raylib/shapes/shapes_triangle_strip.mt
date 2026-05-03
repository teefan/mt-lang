module examples.raylib.shapes.shapes_triangle_strip

import std.c.libm as math
import std.c.raygui as gui
import std.c.raylib as rl
import std.raylib.math as mt_math

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - triangle strip"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var points = zero[array[rl.Vector2, 122]]()
    let center = rl.Vector2(x = screen_width / 2.0 - 125.0, y = screen_height / 2.0)
    var segments: f32 = 6.0
    var inside_radius: f32 = 100.0
    var outside_radius: f32 = 150.0
    var outline = true

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let point_count = i32<-segments
        let angle_step = 360.0 / f32<-point_count * mt_math.deg2rad

        for index in range(0, point_count):
            let point_index = index * 2
            let angle1 = f32<-index * angle_step
            points[point_index] = rl.Vector2(
                x = center.x + math.cosf(angle1) * inside_radius,
                y = center.y + math.sinf(angle1) * inside_radius,
            )

            let angle2 = angle1 + angle_step / 2.0
            points[point_index + 1] = rl.Vector2(
                x = center.x + math.cosf(angle2) * outside_radius,
                y = center.y + math.sinf(angle2) * outside_radius,
            )

        points[point_count * 2] = points[0]
        points[point_count * 2 + 1] = points[1]

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        for index in range(0, point_count):
            let a = points[index * 2]
            let b = points[index * 2 + 1]
            let c = points[index * 2 + 2]
            let d = points[index * 2 + 3]

            let angle1 = f32<-index * angle_step
            rl.DrawTriangle(c, b, a, rl.ColorFromHSV(angle1 * mt_math.rad2deg, 1.0, 1.0))
            rl.DrawTriangle(d, b, c, rl.ColorFromHSV((angle1 + angle_step / 2.0) * mt_math.rad2deg, 1.0, 1.0))

            if outline:
                rl.DrawTriangleLines(a, b, c, rl.BLACK)
                rl.DrawTriangleLines(c, b, d, rl.BLACK)

        rl.DrawLine(580, 0, 580, rl.GetScreenHeight(), rl.Color(r = 218, g = 218, b = 218, a = 255))
        rl.DrawRectangle(580, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), rl.Color(r = 232, g = 232, b = 232, a = 255))

        gui.GuiSliderBar(gui.Rectangle(x = 640.0, y = 40.0, width = 120.0, height = 20.0), c"Segments", rl.TextFormat(c"%.0f", segments), ptr_of(ref_of(segments)), 6.0, 60.0)
        gui.GuiCheckBox(gui.Rectangle(x = 640.0, y = 70.0, width = 20.0, height = 20.0), c"Outline", ptr_of(ref_of(outline)))

        rl.DrawFPS(10, 10)

    return 0
