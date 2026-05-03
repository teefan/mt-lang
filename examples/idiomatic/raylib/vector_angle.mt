module examples.idiomatic.raylib.vector_angle

import std.raylib as rl
import std.raylib.math as math

const screen_width: i32 = 800
const screen_height: i32 = 450


def line_angle(start: rl.Vector2, finish: rl.Vector2) -> f32:
    return math.atan2(finish.y - start.y, finish.x - start.x)


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Vector Angle")
    defer rl.close_window()

    let origin = rl.Vector2(x = f32<-screen_width / 2.0, y = f32<-screen_height / 2.0)
    var first_vector = origin.add(rl.Vector2(x = 100.0, y = 80.0))
    var second_vector = math.Vector2.zero()
    var angle: f32 = 0.0
    var angle_mode = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        var start_angle: f32 = 0.0
        if angle_mode == 0:
            start_angle = -line_angle(origin, first_vector) * math.rad2deg

        second_vector = rl.get_mouse_position()

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            angle_mode = if angle_mode == 0: 1 else: 0

        if angle_mode == 0 and rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            first_vector = rl.get_mouse_position()

        if angle_mode == 0:
            let first_normal = first_vector.subtract(origin).normalize()
            let second_normal = second_vector.subtract(origin).normalize()
            angle = first_normal.angle(second_normal) * math.rad2deg
        else:
            angle = line_angle(origin, second_vector) * math.rad2deg

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        if angle_mode == 0:
            rl.draw_text("MODE 0: Angle between V1 and V2", 10, 10, 20, rl.BLACK)
            rl.draw_text("Right Click to Move V2", 10, 30, 20, rl.DARKGRAY)
            rl.draw_line_ex(origin, first_vector, 2.0, rl.BLACK)
            rl.draw_line_ex(origin, second_vector, 2.0, rl.RED)
            rl.draw_circle_sector(origin, 40.0, start_angle, start_angle + angle, 32, rl.fade(rl.GREEN, 0.6))
        else:
            rl.draw_text("MODE 1: Angle formed by line V1 to V2", 10, 10, 20, rl.BLACK)
            rl.draw_line(0, screen_height / 2, screen_width, screen_height / 2, rl.LIGHTGRAY)
            rl.draw_line_ex(origin, second_vector, 2.0, rl.RED)
            rl.draw_circle_sector(origin, 40.0, start_angle, start_angle - angle, 32, rl.fade(rl.GREEN, 0.6))

        rl.draw_text("v0", i32<-origin.x, i32<-origin.y, 10, rl.DARKGRAY)
        if angle_mode == 0 and origin.subtract(first_vector).y > 0.0:
            rl.draw_text("v1", i32<-first_vector.x, i32<-first_vector.y - 10, 10, rl.DARKGRAY)
        elif angle_mode == 0 and origin.subtract(first_vector).y < 0.0:
            rl.draw_text("v1", i32<-first_vector.x, i32<-first_vector.y, 10, rl.DARKGRAY)
        elif angle_mode == 1:
            rl.draw_text("v1", i32<-origin.x + 40, i32<-origin.y, 10, rl.DARKGRAY)

        rl.draw_text("v2", i32<-second_vector.x - 10, i32<-second_vector.y - 10, 10, rl.DARKGRAY)
        rl.draw_text("Press SPACE to change MODE", 460, 10, 20, rl.DARKGRAY)
        rl.draw_text(rl.text_format_f32("ANGLE: %2.2f", angle), 10, 70, 20, rl.LIME)

    return 0
