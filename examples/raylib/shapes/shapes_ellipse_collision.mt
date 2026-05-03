module examples.raylib.shapes.shapes_ellipse_collision

import std.c.libm as math
import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - collision ellipses"
const ellipses_collide_text: cstr = c"ELLIPSES COLLIDE"
const no_collision_text: cstr = c"NO COLLISION"
const controlling_a_text: cstr = c"Controlling: A"
const controlling_b_text: cstr = c"Controlling: B"
const mouse_inside_a_text: cstr = c"Mouse inside ellipse A"
const mouse_inside_b_text: cstr = c"Mouse inside ellipse B"
const switch_control_text: cstr = c"Press [A] or [B] to switch control"


def check_collision_point_ellipse(point: rl.Vector2, center: rl.Vector2, radius_x: f32, radius_y: f32) -> bool:
    let dx = (point.x - center.x) / radius_x
    let dy = (point.y - center.y) / radius_y
    return dx * dx + dy * dy <= 1.0


def check_collision_ellipses(center1: rl.Vector2, radius_x1: f32, radius_y1: f32, center2: rl.Vector2, radius_x2: f32, radius_y2: f32) -> bool:
    let dx = center2.x - center1.x
    let dy = center2.y - center1.y
    let distance = math.sqrtf(dx * dx + dy * dy)

    if distance == 0.0:
        return true

    let theta = math.atan2f(dy, dx)
    let cos_theta = math.cosf(theta)
    let sin_theta = math.sinf(theta)

    let r1 = (radius_x1 * radius_y1) / math.sqrtf((radius_y1 * cos_theta) * (radius_y1 * cos_theta) + (radius_x1 * sin_theta) * (radius_x1 * sin_theta))
    let r2 = (radius_x2 * radius_y2) / math.sqrtf((radius_y2 * cos_theta) * (radius_y2 * cos_theta) + (radius_x2 * sin_theta) * (radius_x2 * sin_theta))
    return distance <= r1 + r2


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var ellipse_a_center = rl.Vector2(x = screen_width / 4.0, y = screen_height / 2.0)
    var ellipse_a_radius_x: f32 = 120.0
    var ellipse_a_radius_y: f32 = 70.0

    var ellipse_b_center = rl.Vector2(x = screen_width * 3.0 / 4.0, y = screen_height / 2.0)
    var ellipse_b_radius_x: f32 = 90.0
    var ellipse_b_radius_y: f32 = 140.0

    var controlled: i32 = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_A):
            controlled = 0
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_B):
            controlled = 1

        let mouse_position = rl.GetMousePosition()
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

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawEllipse(
            i32<-ellipse_a_center.x,
            i32<-ellipse_a_center.y,
            ellipse_a_radius_x,
            ellipse_a_radius_y,
            if ellipses_collide: rl.RED else: rl.BLUE,
        )
        rl.DrawEllipse(
            i32<-ellipse_b_center.x,
            i32<-ellipse_b_center.y,
            ellipse_b_radius_x,
            ellipse_b_radius_y,
            if ellipses_collide: rl.RED else: rl.GREEN,
        )

        rl.DrawEllipseLines(i32<-ellipse_a_center.x, i32<-ellipse_a_center.y, ellipse_a_radius_x, ellipse_a_radius_y, rl.WHITE)
        rl.DrawEllipseLines(i32<-ellipse_b_center.x, i32<-ellipse_b_center.y, ellipse_b_radius_x, ellipse_b_radius_y, rl.WHITE)

        rl.DrawCircleV(ellipse_a_center, 4.0, rl.WHITE)
        rl.DrawCircleV(ellipse_b_center, 4.0, rl.WHITE)

        if ellipses_collide:
            rl.DrawText(ellipses_collide_text, screen_width / 2 - 120, 40, 28, rl.RED)
        else:
            rl.DrawText(no_collision_text, screen_width / 2 - 80, 40, 28, rl.DARKGRAY)

        rl.DrawText(if controlled == 0: controlling_a_text else: controlling_b_text, 20, screen_height - 40, 20, rl.YELLOW)

        if mouse_in_a and controlled != 0:
            rl.DrawText(mouse_inside_a_text, 20, screen_height - 70, 20, rl.BLUE)
        if mouse_in_b and controlled != 1:
            rl.DrawText(mouse_inside_b_text, 20, screen_height - 70, 20, rl.GREEN)

        rl.DrawText(switch_control_text, 20, 20, 20, rl.GRAY)

    return 0
