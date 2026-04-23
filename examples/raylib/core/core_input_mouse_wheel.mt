module examples.raylib.core.core_input_mouse_wheel

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - input mouse wheel"
const help_text: cstr = c"Use mouse wheel to move the cube up and down!"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var box_position_y = screen_height / 2 - 40
    let scroll_speed: f32 = 4.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        box_position_y -= cast[i32](rl.GetMouseWheelMove() * scroll_speed)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawRectangle(screen_width / 2 - 40, box_position_y, 80, 80, rl.MAROON)
        rl.DrawText(help_text, 10, 10, 20, rl.GRAY)
        rl.DrawText(rl.TextFormat(c"Box position Y: %03i", box_position_y), 10, 40, 20, rl.LIGHTGRAY)

    return 0
