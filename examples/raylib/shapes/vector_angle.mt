import std.raylib as rl
import std.raymath as math
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const RAD_TO_DEG: float = 180.0 / rl.PI


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - vector angle")
    defer rl.close_window()

    let v0 = rl.Vector2(x = float<-SCREEN_WIDTH / 2.0, y = float<-SCREEN_HEIGHT / 2.0)
    var v1 = math.vector2_add(v0, rl.Vector2(x = 100.0, y = 80.0))
    var v2: rl.Vector2 = zero[rl.Vector2]
    var angle: float = 0.0
    var angle_mode = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        var start_angle: float = 0.0
        if angle_mode == 0:
            start_angle = -(math.vector2_line_angle(v0, v1) * RAD_TO_DEG)

        v2 = rl.get_mouse_position()

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            angle_mode = 1 - angle_mode

        if angle_mode == 0 and rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            v1 = rl.get_mouse_position()

        if angle_mode == 0:
            let v1_normal = math.vector2_normalize(math.vector2_subtract(v1, v0))
            let v2_normal = math.vector2_normalize(math.vector2_subtract(v2, v0))
            angle = math.vector2_angle(v1_normal, v2_normal) * RAD_TO_DEG
        else:
            angle = math.vector2_line_angle(v0, v2) * RAD_TO_DEG

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        if angle_mode == 0:
            rl.draw_text("MODE 0: Angle between V1 and V2", 10, 10, 20, rl.BLACK)
            rl.draw_text("Right Click to Move V1", 10, 30, 20, rl.DARKGRAY)
            rl.draw_line_ex(v0, v1, 2.0, rl.BLACK)
            rl.draw_line_ex(v0, v2, 2.0, rl.RED)
            rl.draw_circle_sector(v0, 40.0, start_angle, start_angle + angle, 32, rl.fade(rl.GREEN, 0.6))
        else:
            rl.draw_text("MODE 1: Angle formed by line V0 to V2", 10, 10, 20, rl.BLACK)
            rl.draw_line(0, SCREEN_HEIGHT / 2, SCREEN_WIDTH, SCREEN_HEIGHT / 2, rl.LIGHTGRAY)
            rl.draw_line_ex(v0, v2, 2.0, rl.RED)
            rl.draw_circle_sector(v0, 40.0, start_angle, start_angle - angle, 32, rl.fade(rl.GREEN, 0.6))

        rl.draw_text("v0", int<-v0.x, int<-v0.y, 10, rl.DARKGRAY)

        let line_direction = math.vector2_subtract(v0, v1)
        if angle_mode == 0 and line_direction.y > 0.0:
            rl.draw_text("v1", int<-v1.x, int<-v1.y - 10, 10, rl.DARKGRAY)
        if angle_mode == 0 and line_direction.y < 0.0:
            rl.draw_text("v1", int<-v1.x, int<-v1.y, 10, rl.DARKGRAY)
        if angle_mode == 1:
            rl.draw_text("v1", int<-v0.x + 40, int<-v0.y, 10, rl.DARKGRAY)

        rl.draw_text("v2", int<-v2.x - 10, int<-v2.y - 10, 10, rl.DARKGRAY)
        rl.draw_text("Press SPACE to change MODE", 460, 10, 20, rl.DARKGRAY)
        rl.draw_text(text.cstr_as_str(rl.text_format("ANGLE: %2.2f", angle)), 10, 70, 20, rl.LIME)

        rl.end_drawing()

    return 0
