module examples.raylib.shapes.shapes_math_angle_rotation

import std.c.libm as math
import std.c.raylib as rl
import std.math as mt_math

const screen_width: i32 = 720
const screen_height: i32 = 400
const line_length: f32 = 150.0
const angle_count: i32 = 4
const window_title: cstr = c"raylib [shapes] example - math angle rotation"
const title_text: cstr = c"Fixed angles + rotating line"
const label_format: cstr = c"%d deg"

def line_color(index: i32) -> rl.Color:
    if index == 0:
        return rl.GREEN
    if index == 1:
        return rl.ORANGE
    if index == 2:
        return rl.BLUE
    if index == 3:
        return rl.MAGENTA
    return rl.WHITE

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let center = rl.Vector2(x = screen_width / 2.0, y = screen_height / 2.0)

    var angles = zero[array[i32, 4]]()
    angles[0] = 0
    angles[1] = 30
    angles[2] = 60
    angles[3] = 90

    var total_angle: f32 = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        total_angle += 1.0
        if total_angle >= 360.0:
            total_angle -= 360.0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.WHITE)
        rl.DrawText(title_text, 10, 10, 20, rl.LIGHTGRAY)

        for index in range(0, angle_count):
            let radians = f32<-angles[index] * mt_math.deg2rad
            let end = rl.Vector2(
                x = center.x + math.cosf(radians) * line_length,
                y = center.y + math.sinf(radians) * line_length,
            )
            let color = line_color(index)

            rl.DrawLineEx(center, end, 5.0, color)

            let text_position = rl.Vector2(
                x = center.x + math.cosf(radians) * (line_length + 20.0),
                y = center.y + math.sinf(radians) * (line_length + 20.0),
            )
            rl.DrawText(rl.TextFormat(label_format, angles[index]), i32<-text_position.x, i32<-text_position.y, 20, color)

        let animated_radians = total_angle * mt_math.deg2rad
        let animated_end = rl.Vector2(
            x = center.x + math.cosf(animated_radians) * line_length,
            y = center.y + math.sinf(animated_radians) * line_length,
        )
        let animated_color = rl.ColorFromHSV(total_angle, 0.8, 0.9)
        rl.DrawLineEx(center, animated_end, 5.0, animated_color)

    return 0
