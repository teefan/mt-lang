module examples.idiomatic.raylib.random_values

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Random Values")
    defer rl.close_window()

    var random_value = rl.get_random_value(-8, 5)
    var frames_counter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        frames_counter += 1

        if (frames_counter / 120) % 2 == 1:
            random_value = rl.get_random_value(-8, 5)
            frames_counter = 0

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("Every 2 seconds a new random value is generated:", 130, 100, 20, rl.MAROON)
        rl.draw_text(rl.text_format_i32("%i", random_value), 360, 180, 80, rl.LIGHTGRAY)

    return 0
