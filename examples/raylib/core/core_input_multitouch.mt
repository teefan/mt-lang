module examples.raylib.core.core_input_multitouch

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const max_touch_points: i32 = 10
const window_title: cstr = c"raylib [core] example - input multitouch"
const help_text: cstr = c"touch the screen at multiple locations to get multiple balls"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let touch_radius: f32 = 34.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        var touch_count = rl.GetTouchPointCount()
        if touch_count > max_touch_points:
            touch_count = max_touch_points

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        for index in range(0, touch_count):
            let touch_position = rl.GetTouchPosition(index)
            if touch_position.x > 0.0 and touch_position.y > 0.0:
                rl.DrawCircleV(touch_position, touch_radius, rl.ORANGE)

        rl.DrawText(help_text, 10, 10, 20, rl.DARKGRAY)

    return 0