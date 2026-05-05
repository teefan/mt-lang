module examples.idiomatic.raylib.window_should_close

import std.raylib as rl

const screen_width: int = 800
const screen_height: int = 450


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea Exit Prompt")
    defer rl.close_window()

    rl.set_exit_key(rl.KeyboardKey.KEY_NULL)

    var exit_window_requested = false
    var exit_window = false

    rl.set_target_fps(60)

    while not exit_window:
        if rl.window_should_close() or rl.is_key_pressed(rl.KeyboardKey.KEY_ESCAPE):
            exit_window_requested = true

        if exit_window_requested:
            if rl.is_key_pressed(rl.KeyboardKey.KEY_Y):
                exit_window = true
            elif rl.is_key_pressed(rl.KeyboardKey.KEY_N):
                exit_window_requested = false

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        if exit_window_requested:
            rl.draw_rectangle(0, 100, screen_width, 200, rl.BLACK)
            rl.draw_text("Are you sure you want to exit program? [Y/N]", 40, 180, 30, rl.WHITE)
        else:
            rl.draw_text("Try to close the window to get confirmation message!", 120, 200, 20, rl.LIGHTGRAY)

    return 0
