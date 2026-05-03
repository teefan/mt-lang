module examples.raylib.text.text_format_text

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [text] example - format text"
const score_format: cstr = c"Score: %08i"
const hiscore_format: cstr = c"HiScore: %08i"
const lives_format: cstr = c"Lives: %02i"
const elapsed_time_format: cstr = c"Elapsed Time: %02.02f ms"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let score = 100020
    let hiscore = 200450
    let lives = 5

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawText(rl.TextFormat(score_format, score), 200, 80, 20, rl.RED)
        rl.DrawText(rl.TextFormat(hiscore_format, hiscore), 200, 120, 20, rl.GREEN)
        rl.DrawText(rl.TextFormat(lives_format, lives), 200, 160, 40, rl.BLUE)
        rl.DrawText(rl.TextFormat(elapsed_time_format, rl.GetFrameTime() * 1000.0), 200, 220, 20, rl.BLACK)

    return 0
