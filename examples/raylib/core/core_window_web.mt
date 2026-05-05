module examples.raylib.core.core_window_web

import std.c.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [core] example - window web"
const message_text: cstr = c"Welcome to raylib web structure!"


def update_draw_frame() -> void:
    rl.BeginDrawing()
    defer rl.EndDrawing()

    rl.ClearBackground(rl.RAYWHITE)
    rl.DrawText(message_text, 220, 200, 20, rl.SKYBLUE)


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        update_draw_frame()

    return 0
