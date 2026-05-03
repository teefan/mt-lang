module examples.raylib.shapes.shapes_vector_angle

import std.c.raylib as rl
import std.math as math
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - vector angle"
const mode_zero_title: cstr = c"MODE 0: Angle between V1 and V2"
const mode_zero_help: cstr = c"Right Click to Move V2"
const mode_one_title: cstr = c"MODE 1: Angle formed by line V1 to V2"
const mode_help: cstr = c"Press SPACE to change MODE"
const v0_label: cstr = c"v0"
const v1_label: cstr = c"v1"
const v2_label: cstr = c"v2"
const angle_format: cstr = c"ANGLE: %2.2f"


def line_angle(start: rl.Vector2, finish: rl.Vector2) -> f32:
    return rm.atan2(finish.y - start.y, finish.x - start.x)


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let v0 = rl.Vector2(x = screen_width / 2.0, y = screen_height / 2.0)
    var v1 = v0.add(rl.Vector2(x = 100.0, y = 80.0))
    var v2 = rm.Vector2.zero()

    var angle: f32 = 0.0
    var angle_mode = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        var start_angle: f32 = 0.0

        if angle_mode == 0:
            start_angle = -line_angle(v0, v1) * math.rad2deg
        else:
            start_angle = 0.0

        v2 = rl.GetMousePosition()

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            if angle_mode == 0:
                angle_mode = 1
            else:
                angle_mode = 0

        if angle_mode == 0 and rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            v1 = rl.GetMousePosition()

        if angle_mode == 0:
            let v1_normal = v1.subtract(v0).normalize()
            let v2_normal = v2.subtract(v0).normalize()
            angle = v1_normal.angle(v2_normal) * math.rad2deg
        else:
            angle = line_angle(v0, v2) * math.rad2deg

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        if angle_mode == 0:
            rl.DrawText(mode_zero_title, 10, 10, 20, rl.BLACK)
            rl.DrawText(mode_zero_help, 10, 30, 20, rl.DARKGRAY)
            rl.DrawLineEx(v0, v1, 2.0, rl.BLACK)
            rl.DrawLineEx(v0, v2, 2.0, rl.RED)
            rl.DrawCircleSector(v0, 40.0, start_angle, start_angle + angle, 32, rl.Fade(rl.GREEN, 0.6))
        else:
            rl.DrawText(mode_one_title, 10, 10, 20, rl.BLACK)
            rl.DrawLine(0, screen_height / 2, screen_width, screen_height / 2, rl.LIGHTGRAY)
            rl.DrawLineEx(v0, v2, 2.0, rl.RED)
            rl.DrawCircleSector(v0, 40.0, start_angle, start_angle - angle, 32, rl.Fade(rl.GREEN, 0.6))

        rl.DrawText(v0_label, i32<-v0.x, i32<-v0.y, 10, rl.DARKGRAY)

        if angle_mode == 0 and v0.subtract(v1).y > 0.0:
            rl.DrawText(v1_label, i32<-v1.x, i32<-v1.y - 10, 10, rl.DARKGRAY)
        elif angle_mode == 0 and v0.subtract(v1).y < 0.0:
            rl.DrawText(v1_label, i32<-v1.x, i32<-v1.y, 10, rl.DARKGRAY)

        if angle_mode == 1:
            rl.DrawText(v1_label, i32<-v0.x + 40, i32<-v0.y, 10, rl.DARKGRAY)

        rl.DrawText(v2_label, i32<-v2.x - 10, i32<-v2.y - 10, 10, rl.DARKGRAY)
        rl.DrawText(mode_help, 460, 10, 20, rl.DARKGRAY)
        rl.DrawText(rl.TextFormat(angle_format, angle), 10, 70, 20, rl.LIME)

    return 0
