module examples.raylib.shapes.shapes_easings_box

import std.c.libm as math
import std.c.raylib as rl
import std.math as mt_math

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - easings box"
const reset_text: cstr = c"PRESS [SPACE] TO RESET BOX ANIMATION!"

def pow2(exponent: f32) -> f32:
    return math.expf(math.logf(2.0) * exponent)

def ease_linear_in(t: f32, b: f32, c: f32, d: f32) -> f32:
    return c * t / d + b

def ease_sine_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    return c * math.sinf(t / d * (mt_math.pi / 2.0)) + b

def ease_circ_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    let normalized = t / d - 1.0
    return c * math.sqrtf(1.0 - normalized * normalized) + b

def ease_quad_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    let normalized = t / d
    return -c * normalized * (normalized - 2.0) + b

def ease_bounce_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    var normalized = t / d

    if normalized < 1.0 / 2.75:
        return c * (7.5625 * normalized * normalized) + b
    elif normalized < 2.0 / 2.75:
        normalized -= 1.5 / 2.75
        return c * (7.5625 * normalized * normalized + 0.75) + b
    elif normalized < 2.5 / 2.75:
        normalized -= 2.25 / 2.75
        return c * (7.5625 * normalized * normalized + 0.9375) + b

    normalized -= 2.625 / 2.75
    return c * (7.5625 * normalized * normalized + 0.984375) + b

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

    let center_x = rl.GetScreenWidth() / 2.0
    let center_y_delta = f32<-(rl.GetScreenHeight() / 2 + 100)

    var rec = rl.Rectangle(x = center_x, y = -100.0, width = 100.0, height = 100.0)
    var rotation: f32 = 0.0
    var alpha: f32 = 1.0

    var state = 0
    var frames_counter = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if state == 0:
            frames_counter += 1
            rec.y = ease_elastic_out(f32<-frames_counter, -100.0, center_y_delta, 120.0)

            if frames_counter >= 120:
                frames_counter = 0
                state = 1
        elif state == 1:
            frames_counter += 1
            rec.height = ease_bounce_out(f32<-frames_counter, 100.0, -90.0, 120.0)
            rec.width = ease_bounce_out(f32<-frames_counter, 100.0, f32<-rl.GetScreenWidth(), 120.0)

            if frames_counter >= 120:
                frames_counter = 0
                state = 2
        elif state == 2:
            frames_counter += 1
            rotation = ease_quad_out(f32<-frames_counter, 0.0, 270.0, 240.0)

            if frames_counter >= 240:
                frames_counter = 0
                state = 3
        elif state == 3:
            frames_counter += 1
            rec.height = ease_circ_out(f32<-frames_counter, 10.0, f32<-rl.GetScreenWidth(), 120.0)

            if frames_counter >= 120:
                frames_counter = 0
                state = 4
        elif state == 4:
            frames_counter += 1
            alpha = ease_sine_out(f32<-frames_counter, 1.0, -1.0, 160.0)

            if frames_counter >= 160:
                frames_counter = 0
                state = 5

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            rec = rl.Rectangle(x = center_x, y = -100.0, width = 100.0, height = 100.0)
            rotation = 0.0
            alpha = 1.0
            state = 0
            frames_counter = 0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawRectanglePro(rec, rl.Vector2(x = rec.width / 2.0, y = rec.height / 2.0), rotation, rl.Fade(rl.BLACK, alpha))
        rl.DrawText(reset_text, 10, rl.GetScreenHeight() - 25, 20, rl.LIGHTGRAY)

    return 0