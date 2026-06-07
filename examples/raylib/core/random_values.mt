import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - random values")
    defer rl.close_window()

    var rand_value = rl.get_random_value(-8, 5)
    var frames_counter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        frames_counter += 1

        if ((frames_counter / 120) % 2) == 1:
            rand_value = rl.get_random_value(-8, 5)
            frames_counter = 0

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text("Every 2 seconds a new random value is generated:", 130, 100, 20, rl.MAROON)
        rl.draw_text(f"#{rand_value}", 360, 180, 80, rl.LIGHTGRAY)

        rl.end_drawing()

    return 0
