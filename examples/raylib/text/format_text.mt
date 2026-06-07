import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [text] example - format text")
    defer rl.close_window()

    let score = 100020
    let hiscore = 200450
    let lives = 5

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let score_text = rl.text_format("Score: %08i", score)
        let high_score_text = rl.text_format("HiScore: %08i", hiscore)
        let lives_text = rl.text_format("Lives: %02i", lives)
        let elapsed_time_text = rl.text_format("Elapsed Time: %02.02f ms", rl.get_frame_time() * 1000.0)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text(score_text, 200, 80, 20, rl.RED)
        rl.draw_text(high_score_text, 200, 120, 20, rl.GREEN)
        rl.draw_text(lives_text, 200, 160, 40, rl.BLUE)
        rl.draw_text(elapsed_time_text, 200, 220, 20, rl.BLACK)

        rl.end_drawing()

    return 0
