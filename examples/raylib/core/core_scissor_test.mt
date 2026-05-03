module examples.raylib.core.core_scissor_test

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - scissor test"
const reveal_text: cstr = c"Move the mouse around to reveal this text!"
const toggle_text: cstr = c"Press S to toggle scissor test"
const scissor_width: f32 = 300.0
const scissor_height: f32 = 300.0
const scissor_half_width: f32 = 150.0
const scissor_half_height: f32 = 150.0


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var scissor_area = rl.Rectangle(x = 0.0, y = 0.0, width = scissor_width, height = scissor_height)
    var scissor_mode = true

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_S):
            scissor_mode = not scissor_mode

        scissor_area.x = rl.GetMouseX() - scissor_half_width
        scissor_area.y = rl.GetMouseY() - scissor_half_height

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        if scissor_mode:
            rl.BeginScissorMode(
                scissor_area.x,
                scissor_area.y,
                scissor_area.width,
                scissor_area.height,
            )

        rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), rl.RED)
        rl.DrawText(reveal_text, 190, 200, 20, rl.LIGHTGRAY)

        if scissor_mode:
            rl.EndScissorMode()

        rl.DrawRectangleLinesEx(scissor_area, 1.0, rl.BLACK)
        rl.DrawText(toggle_text, 10, 10, 20, rl.BLACK)

    return 0
