module examples.idiomatic.raylib.format_text

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Format Text")
    defer rl.close_window()

    let score = 100020
    let hiscore = 200450
    let lives = 5

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        rl.draw_text(rl.text_format_i32("Score: %08i", score), 200, 80, 20, rl.RED)
        rl.draw_text(rl.text_format_i32("HiScore: %08i", hiscore), 200, 120, 20, rl.GREEN)
        rl.draw_text(rl.text_format_i32("Lives: %02i", lives), 200, 160, 40, rl.BLUE)
        rl.draw_text(rl.text_format_f32("Elapsed Time: %02.02f ms", rl.get_frame_time() * 1000.0), 200, 220, 20, rl.BLACK)

    return 0