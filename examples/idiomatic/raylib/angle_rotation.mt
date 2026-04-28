module examples.idiomatic.raylib.angle_rotation

import std.raylib as rl
import std.raylib.math as math

const screen_width: i32 = 720
const screen_height: i32 = 400
const line_length: f32 = 150.0
const angle_count: i32 = 4

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
    rl.init_window(screen_width, screen_height, "Milk Tea Angle Rotation")
    defer rl.close_window()

    let center = rl.Vector2(x = cast[f32](screen_width) / 2.0, y = cast[f32](screen_height) / 2.0)
    var angles = zero[array[i32, 4]]()
    angles[0] = 0
    angles[1] = 30
    angles[2] = 60
    angles[3] = 90
    var total_angle: f32 = 0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        total_angle += 1.0
        if total_angle >= 360.0:
            total_angle -= 360.0

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.WHITE)
        rl.draw_text("Fixed angles + rotating line", 10, 10, 20, rl.LIGHTGRAY)

        for index in range(0, angle_count):
            let radians = cast[f32](angles[index]) * math.deg2rad
            let end_point = rl.Vector2(
                x = center.x + math.cos(radians) * line_length,
                y = center.y + math.sin(radians) * line_length,
            )
            let color = line_color(index)
            rl.draw_line_ex(center, end_point, 5.0, color)

            let label_position = rl.Vector2(
                x = center.x + math.cos(radians) * (line_length + 20.0),
                y = center.y + math.sin(radians) * (line_length + 20.0),
            )
            rl.draw_text(rl.text_format_i32("%d deg", angles[index]), cast[i32](label_position.x), cast[i32](label_position.y), 20, color)

        let animated_radians = total_angle * math.deg2rad
        let animated_end = rl.Vector2(
            x = center.x + math.cos(animated_radians) * line_length,
            y = center.y + math.sin(animated_radians) * line_length,
        )
        rl.draw_line_ex(center, animated_end, 5.0, rl.color_from_hsv(total_angle, 0.8, 0.9))

    return 0
