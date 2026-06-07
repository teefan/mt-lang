import std.math as math
import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function check_collision_point_ellipse(point: rl.Vector2, center: rl.Vector2, rx: float, ry: float) -> bool:
    let dx = (point.x - center.x) / rx
    let dy = (point.y - center.y) / ry
    return ((dx * dx) + (dy * dy)) <= 1.0


function check_collision_ellipses(
    c1: rl.Vector2,
    rx1: float,
    ry1: float,
    c2: rl.Vector2,
    rx2: float,
    ry2: float
) -> bool:
    let dx = c2.x - c1.x
    let dy = c2.y - c1.y
    let distance = float<-math.sqrt(double<-((dx * dx) + (dy * dy)))

    if distance == 0.0:
        return true

    let theta = float<-math.atan2(double<-dy, double<-dx)
    let cos_t = float<-math.cos(double<-theta)
    let sin_t = float<-math.sin(double<-theta)
    let r1 = (rx1 * ry1) / float<-math.sqrt(double<-(((ry1 * cos_t) * (ry1 * cos_t)) + ((rx1 * sin_t) * (rx1 * sin_t))))
    let r2 = (rx2 * ry2) / float<-math.sqrt(double<-(((ry2 * cos_t) * (ry2 * cos_t)) + ((rx2 * sin_t) * (rx2 * sin_t))))
    return distance <= (r1 + r2)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - collision ellipses")
    defer rl.close_window()

    var ellipse_a_center = rl.Vector2(x = float<-SCREEN_WIDTH / 4.0, y = float<-SCREEN_HEIGHT / 2.0)
    let ellipse_a_rx: float = 120.0
    let ellipse_a_ry: float = 70.0
    var ellipse_b_center = rl.Vector2(x = (float<-SCREEN_WIDTH * 3.0) / 4.0, y = float<-SCREEN_HEIGHT / 2.0)
    let ellipse_b_rx: float = 90.0
    let ellipse_b_ry: float = 140.0
    var controlled = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_A):
            controlled = 0
        if rl.is_key_pressed(rl.KeyboardKey.KEY_B):
            controlled = 1

        if controlled == 0:
            ellipse_a_center = rl.get_mouse_position()
        else:
            ellipse_b_center = rl.get_mouse_position()

        let ellipses_collide = check_collision_ellipses(
            ellipse_a_center,
            ellipse_a_rx,
            ellipse_a_ry,
            ellipse_b_center,
            ellipse_b_rx,
            ellipse_b_ry
        )
        let mouse_position = rl.get_mouse_position()
        let mouse_in_a = check_collision_point_ellipse(mouse_position, ellipse_a_center, ellipse_a_rx, ellipse_a_ry)
        let mouse_in_b = check_collision_point_ellipse(mouse_position, ellipse_b_center, ellipse_b_rx, ellipse_b_ry)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_ellipse(
            int<-ellipse_a_center.x,
            int<-ellipse_a_center.y,
            ellipse_a_rx,
            ellipse_a_ry,
            if ellipses_collide: rl.RED else: rl.BLUE
        )
        rl.draw_ellipse(
            int<-ellipse_b_center.x,
            int<-ellipse_b_center.y,
            ellipse_b_rx,
            ellipse_b_ry,
            if ellipses_collide: rl.RED else: rl.GREEN
        )
        rl.draw_ellipse_lines(int<-ellipse_a_center.x, int<-ellipse_a_center.y, ellipse_a_rx, ellipse_a_ry, rl.WHITE)
        rl.draw_ellipse_lines(int<-ellipse_b_center.x, int<-ellipse_b_center.y, ellipse_b_rx, ellipse_b_ry, rl.WHITE)
        rl.draw_circle_v(ellipse_a_center, 4.0, rl.WHITE)
        rl.draw_circle_v(ellipse_b_center, 4.0, rl.WHITE)

        if ellipses_collide:
            rl.draw_text("ELLIPSES COLLIDE", (SCREEN_WIDTH / 2) - 120, 40, 28, rl.RED)
        else:
            rl.draw_text("NO COLLISION", (SCREEN_WIDTH / 2) - 80, 40, 28, rl.DARKGRAY)

        rl.draw_text(if controlled == 0: "Controlling: A" else: "Controlling: B", 20, SCREEN_HEIGHT - 40, 20, rl.YELLOW)
        if mouse_in_a and controlled != 0:
            rl.draw_text("Mouse inside ellipse A", 20, SCREEN_HEIGHT - 70, 20, rl.BLUE)
        if mouse_in_b and controlled != 1:
            rl.draw_text("Mouse inside ellipse B", 20, SCREEN_HEIGHT - 70, 20, rl.GREEN)
        rl.draw_text("Press [A] or [B] to switch control", 20, 20, 20, rl.GRAY)
        rl.end_drawing()

    return 0
