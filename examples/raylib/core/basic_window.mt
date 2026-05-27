import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - basic window")
    defer rl.close_window()

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("Congrats! You created your first window!", 190, 200, 20, rl.LIGHTGRAY)
        rl.end_drawing()

    return 0