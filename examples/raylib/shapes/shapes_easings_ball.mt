module examples.raylib.shapes.shapes_easings_ball

import std.c.libm as math
import std.c.raylib as rl
import std.math as mt_math

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - easings ball"
const replay_text: cstr = c"PRESS [ENTER] TO PLAY AGAIN!"

def pow2(exponent: f32) -> f32:
    return math.expf(math.logf(2.0) * exponent)

def ease_cubic_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    let normalized = t / d - 1.0
    return c * (normalized * normalized * normalized + 1.0) + b

def ease_elastic_in(t: f32, b: f32, c: f32, d: f32) -> f32:
    if t == 0.0:
        return b

    var normalized = t / d
    if normalized == 1.0:
        return b + c

    let period = d * 0.3
    let amplitude = c
    let shift = period / 4.0
    normalized -= 1.0

    let post_fix = amplitude * pow2(10.0 * normalized)
    return -(post_fix * math.sinf((normalized * d - shift) * mt_math.tau / period)) + b

def ease_elastic_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    if t == 0.0:
        return b

    let normalized = t / d
    if normalized == 1.0:
        return b + c

    let period = d * 0.3
    let amplitude = c
    let shift = period / 4.0

    return amplitude * pow2(-10.0 * normalized) * math.sinf((normalized * d - shift) * mt_math.tau / period) + c + b

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var ball_position_x = -100
    var ball_radius = 20
    var ball_alpha: f32 = 0.0
    let ball_position_delta = f32<-(screen_width / 2 + 100)

    var state = 0
    var frames_counter = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if state == 0:
            frames_counter += 1
            ball_position_x = i32<-ease_elastic_out(f32<-frames_counter, -100.0, ball_position_delta, 120.0)

            if frames_counter >= 120:
                frames_counter = 0
                state = 1
        elif state == 1:
            frames_counter += 1
            ball_radius = i32<-ease_elastic_in(f32<-frames_counter, 20.0, 500.0, 200.0)

            if frames_counter >= 200:
                frames_counter = 0
                state = 2
        elif state == 2:
            frames_counter += 1
            ball_alpha = ease_cubic_out(f32<-frames_counter, 0.0, 1.0, 200.0)

            if frames_counter >= 200:
                frames_counter = 0
                state = 3
        elif state == 3:
            if rl.IsKeyPressed(rl.KeyboardKey.KEY_ENTER):
                ball_position_x = -100
                ball_radius = 20
                ball_alpha = 0.0
                state = 0

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_R):
            frames_counter = 0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        if state >= 2:
            rl.DrawRectangle(0, 0, screen_width, screen_height, rl.GREEN)

        rl.DrawCircle(ball_position_x, 200, f32<-ball_radius, rl.Fade(rl.RED, 1.0 - ball_alpha))

        if state == 3:
            rl.DrawText(replay_text, 240, 200, 20, rl.BLACK)

    return 0