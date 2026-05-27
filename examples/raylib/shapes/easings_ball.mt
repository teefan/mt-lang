import std.raylib.easing as ease
import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - easings ball")
    defer rl.close_window()

    var ball_position_x = -100
    var ball_radius = 20
    var ball_alpha: float = 0.0
    var state = 0
    var frames_counter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if state == 0:
            frames_counter += 1
            ball_position_x = int<-ease.elastic_out(float<-frames_counter, -100.0, float<-SCREEN_WIDTH / 2.0 + 100.0, 120.0)

            if frames_counter >= 120:
                frames_counter = 0
                state = 1
        else if state == 1:
            frames_counter += 1
            ball_radius = int<-ease.elastic_in(float<-frames_counter, 20.0, 500.0, 200.0)

            if frames_counter >= 200:
                frames_counter = 0
                state = 2
        else if state == 2:
            frames_counter += 1
            ball_alpha = ease.cubic_out(float<-frames_counter, 0.0, 1.0, 200.0)

            if frames_counter >= 200:
                frames_counter = 0
                state = 3
        else if state == 3:
            if rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER):
                ball_position_x = -100
                ball_radius = 20
                ball_alpha = 0.0
                state = 0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            frames_counter = 0

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        if state >= 2:
            rl.draw_rectangle(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, rl.GREEN)
        rl.draw_circle(ball_position_x, 200, float<-ball_radius, rl.fade(rl.RED, 1.0 - ball_alpha))

        if state == 3:
            rl.draw_text("PRESS [ENTER] TO PLAY AGAIN!", 240, 200, 20, rl.BLACK)

        rl.end_drawing()

    return 0
