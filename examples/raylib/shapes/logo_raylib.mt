import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - logo raylib")
    defer rl.close_window()

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_rectangle((SCREEN_WIDTH / 2) - 128, (SCREEN_HEIGHT / 2) - 128, 256, 256, rl.BLACK)
        rl.draw_rectangle((SCREEN_WIDTH / 2) - 112, (SCREEN_HEIGHT / 2) - 112, 224, 224, rl.RAYWHITE)
        rl.draw_text("raylib", (SCREEN_WIDTH / 2) - 44, (SCREEN_HEIGHT / 2) + 48, 50, rl.BLACK)
        rl.draw_text("this is NOT a texture!", 350, 370, 10, rl.GRAY)

        rl.end_drawing()

    return 0
