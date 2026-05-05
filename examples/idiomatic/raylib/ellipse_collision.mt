module examples.idiomatic.raylib.ellipse_collision

import std.raylib as rl
import std.raylib.math as math

const screen_width: int = 800
const screen_height: int = 450


def check_collision_point_ellipse(point: rl.Vector2, center: rl.Vector2, radius_x: float, radius_y: float) -> bool:
    let dx = (point.x - center.x) / radius_x
    let dy = (point.y - center.y) / radius_y
    return dx * dx + dy * dy <= 1.0


def check_collision_ellipses(center_a: rl.Vector2, radius_x_a: float, radius_y_a: float, center_b: rl.Vector2, radius_x_b: float, radius_y_b: float) -> bool:
    let dx = center_b.x - center_a.x
    let dy = center_b.y - center_a.y
    let distance = math.sqrt(dx * dx + dy * dy)
    if distance == 0.0:
        return true

    let theta = math.atan2(dy, dx)
    let cos_theta = math.cos(theta)
    let sin_theta = math.sin(theta)
    let radius_a = (radius_x_a * radius_y_a) / math.sqrt((radius_y_a * cos_theta) * (radius_y_a * cos_theta) + (radius_x_a * sin_theta) * (radius_x_a * sin_theta))
    let radius_b = (radius_x_b * radius_y_b) / math.sqrt((radius_y_b * cos_theta) * (radius_y_b * cos_theta) + (radius_x_b * sin_theta) * (radius_x_b * sin_theta))
    return distance <= radius_a + radius_b


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea Ellipse Collision")
    defer rl.close_window()

    var ellipse_a_center = rl.Vector2(x = float<-screen_width / 4.0, y = float<-screen_height / 2.0)
    let ellipse_a_radius_x: float = 120.0
    let ellipse_a_radius_y: float = 70.0
    var ellipse_b_center = rl.Vector2(x = float<-screen_width * 3.0 / 4.0, y = float<-screen_height / 2.0)
    let ellipse_b_radius_x: float = 90.0
    let ellipse_b_radius_y: float = 140.0
    var controlled = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_A):
            controlled = 0
        if rl.is_key_pressed(rl.KeyboardKey.KEY_B):
            controlled = 1

        let mouse_position = rl.get_mouse_position()
        if controlled == 0:
            ellipse_a_center = mouse_position
        else:
            ellipse_b_center = mouse_position

        let ellipses_collide = check_collision_ellipses(
            ellipse_a_center,
            ellipse_a_radius_x,
            ellipse_a_radius_y,
            ellipse_b_center,
            ellipse_b_radius_x,
            ellipse_b_radius_y,
        )
        let mouse_in_a = check_collision_point_ellipse(mouse_position, ellipse_a_center, ellipse_a_radius_x, ellipse_a_radius_y)
        let mouse_in_b = check_collision_point_ellipse(mouse_position, ellipse_b_center, ellipse_b_radius_x, ellipse_b_radius_y)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_ellipse(int<-ellipse_a_center.x, int<-ellipse_a_center.y, ellipse_a_radius_x, ellipse_a_radius_y, if ellipses_collide: rl.RED else: rl.BLUE)
        rl.draw_ellipse(int<-ellipse_b_center.x, int<-ellipse_b_center.y, ellipse_b_radius_x, ellipse_b_radius_y, if ellipses_collide: rl.RED else: rl.GREEN)
        rl.draw_ellipse_lines(int<-ellipse_a_center.x, int<-ellipse_a_center.y, ellipse_a_radius_x, ellipse_a_radius_y, rl.WHITE)
        rl.draw_ellipse_lines(int<-ellipse_b_center.x, int<-ellipse_b_center.y, ellipse_b_radius_x, ellipse_b_radius_y, rl.WHITE)
        rl.draw_circle_v(ellipse_a_center, 4.0, rl.WHITE)
        rl.draw_circle_v(ellipse_b_center, 4.0, rl.WHITE)

        if ellipses_collide:
            rl.draw_text("ELLIPSES COLLIDE", screen_width / 2 - 120, 40, 28, rl.RED)
        else:
            rl.draw_text("NO COLLISION", screen_width / 2 - 80, 40, 28, rl.DARKGRAY)

        rl.draw_text(if controlled == 0: "Controlling: A" else: "Controlling: B", 20, screen_height - 40, 20, rl.YELLOW)
        if mouse_in_a and controlled != 0:
            rl.draw_text("Mouse inside ellipse A", 20, screen_height - 70, 20, rl.BLUE)
        if mouse_in_b and controlled != 1:
            rl.draw_text("Mouse inside ellipse B", 20, screen_height - 70, 20, rl.GREEN)
        rl.draw_text("Press [A] or [B] to switch control", 20, 20, 20, rl.GRAY)

    return 0
