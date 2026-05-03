module examples.raylib.shapes.shapes_logo_raylib

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - logo raylib"
const raylib_text: cstr = c"raylib"
const texture_text: cstr = c"this is NOT a texture!"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.BeginDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawRectangle(screen_width / 2 - 128, screen_height / 2 - 128, 256, 256, rl.BLACK)
        rl.DrawRectangle(screen_width / 2 - 112, screen_height / 2 - 112, 224, 224, rl.RAYWHITE)
        rl.DrawText(raylib_text, screen_width / 2 - 44, screen_height / 2 + 48, 50, rl.BLACK)
        rl.DrawText(texture_text, 350, 370, 10, rl.GRAY)

        rl.EndDrawing()

    return 0
