module examples.raylib.text.text_writing_anim

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [text] example - writing anim"
const message: cstr = c"This sample illustrates a text writing\nanimation effect! Check it out! ;)"
const restart_text: cstr = c"PRESS [ENTER] to RESTART!"
const speed_text: cstr = c"HOLD [SPACE] to SPEED UP!"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var frames_counter = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyDown(rl.KeyboardKey.KEY_SPACE):
            frames_counter += 8
        else:
            frames_counter += 1

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_ENTER):
            frames_counter = 0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawText(rl.TextSubtext(message, 0, frames_counter / 10), 210, 160, 20, rl.MAROON)
        rl.DrawText(restart_text, 240, 260, 20, rl.LIGHTGRAY)
        rl.DrawText(speed_text, 239, 300, 20, rl.LIGHTGRAY)

    return 0
