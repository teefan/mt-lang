module examples.idiomatic.raylib.easings_ball

import std.easing as ease
import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Easings Ball")
    defer rl.close_window()

    var ball_position_x = -100
    var ball_radius = 20
    var ball_alpha: f32 = 0.0
    let ball_position_delta = f32<-(screen_width / 2 + 100)

    var state = 0
    var frames_counter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if state == 0:
            frames_counter += 1
            ball_position_x = i32<-ease.elastic_out(f32<-frames_counter, -100.0, ball_position_delta, 120.0)

            if frames_counter >= 120:
                frames_counter = 0
                state = 1
        elif state == 1:
            frames_counter += 1
            ball_radius = i32<-ease.elastic_in(f32<-frames_counter, 20.0, 500.0, 200.0)

            if frames_counter >= 200:
                frames_counter = 0
                state = 2
        elif state == 2:
            frames_counter += 1
            ball_alpha = ease.cubic_out(f32<-frames_counter, 0.0, 1.0, 200.0)

            if frames_counter >= 200:
                frames_counter = 0
                state = 3
        elif state == 3:
            if rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER):
                ball_position_x = -100
                ball_radius = 20
                ball_alpha = 0.0
                state = 0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            frames_counter = 0

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        if state >= 2:
            rl.draw_rectangle(0, 0, screen_width, screen_height, rl.GREEN)

        rl.draw_circle(ball_position_x, 200, f32<-ball_radius, rl.fade(rl.RED, 1.0 - ball_alpha))

        if state == 3:
            rl.draw_text("PRESS [ENTER] TO PLAY AGAIN!", 240, 200, 20, rl.BLACK)

    return 0
