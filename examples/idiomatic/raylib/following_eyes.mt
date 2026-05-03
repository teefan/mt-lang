module examples.idiomatic.raylib.following_eyes

import std.raylib as rl
import std.raylib.math as math

const screen_width: i32 = 800
const screen_height: i32 = 450

def clamp_to_circle(point: rl.Vector2, center: rl.Vector2, radius: f32) -> rl.Vector2:
    if rl.check_collision_point_circle(point, center, radius):
        return point

    let dx = point.x - center.x
    let dy = point.y - center.y
    let angle = math.atan2(dy, dx)
    return rl.Vector2(
        x = center.x + radius * math.cos(angle),
        y = center.y + radius * math.sin(angle),
    )

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Following Eyes")
    defer rl.close_window()

    let center_y = f32<-screen_height / 2.0
    let left_eye = rl.Vector2(x = f32<-screen_width / 2.0 - 100.0, y = center_y)
    let right_eye = rl.Vector2(x = f32<-screen_width / 2.0 + 100.0, y = center_y)
    let sclera_radius: f32 = 80.0
    let iris_radius: f32 = 24.0
    let iris_limit = sclera_radius - iris_radius

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse_position = rl.get_mouse_position()
        let left_iris = clamp_to_circle(mouse_position, left_eye, iris_limit)
        let right_iris = clamp_to_circle(mouse_position, right_eye, iris_limit)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_circle_v(left_eye, sclera_radius, rl.LIGHTGRAY)
        rl.draw_circle_v(left_iris, iris_radius, rl.BROWN)
        rl.draw_circle_v(left_iris, 10.0, rl.BLACK)

        rl.draw_circle_v(right_eye, sclera_radius, rl.LIGHTGRAY)
        rl.draw_circle_v(right_iris, iris_radius, rl.DARKGREEN)
        rl.draw_circle_v(right_iris, 10.0, rl.BLACK)

        rl.draw_fps(10, 10)

    return 0