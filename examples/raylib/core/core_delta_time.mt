module examples.raylib.core.core_delta_time

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - delta time"
const help_text: cstr = c"Use the scroll wheel to change the fps limit, r to reset"
const delta_text: cstr = c"FUNC: x += GetFrameTime()*speed"
const frame_text: cstr = c"FUNC: x += speed"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var current_fps = 60
    var delta_circle = rl.Vector2(x = 0.0, y = 0.33333334 * screen_height)
    var frame_circle = rl.Vector2(x = 0.0, y = 0.6666667 * screen_height)
    let speed: f32 = 10.0
    let circle_radius: f32 = 32.0

    rl.SetTargetFPS(current_fps)

    while not rl.WindowShouldClose():
        let mouse_wheel = rl.GetMouseWheelMove()
        if mouse_wheel != 0.0:
            current_fps += i32<-mouse_wheel
            if current_fps < 0:
                current_fps = 0
            rl.SetTargetFPS(current_fps)

        delta_circle.x += rl.GetFrameTime() * 6.0 * speed
        frame_circle.x += 0.1 * speed

        if delta_circle.x > screen_width:
            delta_circle.x = 0.0
        if frame_circle.x > screen_width:
            frame_circle.x = 0.0

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_R):
            delta_circle.x = 0.0
            frame_circle.x = 0.0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawCircleV(delta_circle, circle_radius, rl.RED)
        rl.DrawCircleV(frame_circle, circle_radius, rl.BLUE)
        if current_fps <= 0:
            rl.DrawText(rl.TextFormat(c"FPS: unlimited (%i)", rl.GetFPS()), 10, 10, 20, rl.DARKGRAY)
        else:
            rl.DrawText(rl.TextFormat(c"FPS: %i (target: %i)", rl.GetFPS(), current_fps), 10, 10, 20, rl.DARKGRAY)
        rl.DrawText(rl.TextFormat(c"Frame time: %.2f ms", rl.GetFrameTime()), 10, 30, 20, rl.DARKGRAY)
        rl.DrawText(help_text, 10, 50, 20, rl.DARKGRAY)
        rl.DrawText(delta_text, 10, 90, 20, rl.RED)
        rl.DrawText(frame_text, 10, 240, 20, rl.BLUE)

    return 0
