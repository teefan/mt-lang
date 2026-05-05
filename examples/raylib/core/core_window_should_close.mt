module examples.raylib.core.core_window_should_close

import std.c.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [core] example - window should close"
const exit_prompt_text: cstr = c"Are you sure you want to exit program? [Y/N]"
const info_text: cstr = c"Try to close the window to get confirmation message!"


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.SetExitKey(rl.KeyboardKey.KEY_NULL)

    var exit_window_requested = false
    var exit_window = false

    rl.SetTargetFPS(60)

    while not exit_window:
        if rl.WindowShouldClose() or rl.IsKeyPressed(rl.KeyboardKey.KEY_ESCAPE):
            exit_window_requested = true

        if exit_window_requested:
            if rl.IsKeyPressed(rl.KeyboardKey.KEY_Y):
                exit_window = true
            elif rl.IsKeyPressed(rl.KeyboardKey.KEY_N):
                exit_window_requested = false

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        if exit_window_requested:
            rl.DrawRectangle(0, 100, screen_width, 200, rl.BLACK)
            rl.DrawText(exit_prompt_text, 40, 180, 30, rl.WHITE)
        else:
            rl.DrawText(info_text, 120, 200, 20, rl.LIGHTGRAY)

    return 0
