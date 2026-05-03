module examples.idiomatic.raylib.logo_raylib

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Raylib Logo")
    defer rl.close_window()

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_rectangle(screen_width / 2 - 128, screen_height / 2 - 128, 256, 256, rl.BLACK)
        rl.draw_rectangle(screen_width / 2 - 112, screen_height / 2 - 112, 224, 224, rl.RAYWHITE)
        rl.draw_text("raylib", screen_width / 2 - 44, screen_height / 2 + 48, 50, rl.BLACK)
        rl.draw_text("this is NOT a texture!", 350, 370, 10, rl.GRAY)

    return 0
