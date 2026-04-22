module examples.raylib.core.core_random_values

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - random values"
const help_text: cstr = c"Every 2 seconds a new random value is generated:"

def random_value_text(value: i32) -> cstr:
    if value == -8:
        return c"-8"
    if value == -7:
        return c"-7"
    if value == -6:
        return c"-6"
    if value == -5:
        return c"-5"
    if value == -4:
        return c"-4"
    if value == -3:
        return c"-3"
    if value == -2:
        return c"-2"
    if value == -1:
        return c"-1"
    if value == 0:
        return c"0"
    if value == 1:
        return c"1"
    if value == 2:
        return c"2"
    if value == 3:
        return c"3"
    if value == 4:
        return c"4"

    return c"5"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var rand_value = rl.GetRandomValue(-8, 5)
    var frames_counter = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        frames_counter += 1

        if (frames_counter / 120) % 2 == 1:
            rand_value = rl.GetRandomValue(-8, 5)
            frames_counter = 0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawText(help_text, 130, 100, 20, rl.MAROON)
        rl.DrawText(random_value_text(rand_value), 360, 180, 80, rl.LIGHTGRAY)

    return 0
