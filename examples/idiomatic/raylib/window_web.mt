module examples.idiomatic.raylib.window_web

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450

def draw_frame() -> void:
    rl.begin_drawing()
    defer rl.end_drawing()

    rl.clear_background(rl.RAYWHITE)
    rl.draw_text("Welcome to raylib web structure!", 220, 200, 20, rl.SKYBLUE)
    return

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Web Window")
    defer rl.close_window()

    rl.set_target_fps(60)

    while not rl.window_should_close():
        draw_frame()

    return 0
