import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - window should close")
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
            else if rl.is_key_pressed(rl.KeyboardKey.KEY_N):
                exit_window_requested = false

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        if exit_window_requested:
            rl.draw_rectangle(0, 100, SCREEN_WIDTH, 200, rl.BLACK)
            rl.draw_text("Are you sure you want to exit program? [Y/N]", 40, 180, 30, rl.WHITE)
        else:
            rl.draw_text("Try to close the window to get confirmation message!", 120, 200, 20, rl.LIGHTGRAY)

        rl.end_drawing()

    return 0
