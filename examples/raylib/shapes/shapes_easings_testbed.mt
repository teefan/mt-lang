module examples.raylib.shapes.shapes_easings_testbed

import std.c.libm as math
import std.c.raylib as rl
import std.math as mt_math

const font_size: i32 = 20

const d_step: f32 = 20.0
const d_step_fine: f32 = 2.0
const d_min: f32 = 1.0
const d_max: f32 = 10000.0

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - easings testbed"

const easing_none: i32 = 28

struct EasingFunc:
    name: cstr
    callback: fn(t: f32, b: f32, c: f32, d: f32) -> f32


def pow2(exponent: f32) -> f32:
    return math.expf(math.logf(2.0) * exponent)


def no_ease(t: f32, b: f32, c: f32, d: f32) -> f32:
    return b


def ease_linear_none(t: f32, b: f32, c: f32, d: f32) -> f32:
    return c * t / d + b


def ease_linear_in(t: f32, b: f32, c: f32, d: f32) -> f32:
    return c * t / d + b


def ease_linear_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    return c * t / d + b


def ease_linear_in_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    return c * t / d + b


def ease_sine_in(t: f32, b: f32, c: f32, d: f32) -> f32:
    return -c * math.cosf(t / d * (mt_math.pi / 2.0)) + c + b


def ease_sine_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    return c * math.sinf(t / d * (mt_math.pi / 2.0)) + b


def ease_sine_in_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    return -c / 2.0 * (math.cosf(mt_math.pi * t / d) - 1.0) + b


def ease_circ_in(t: f32, b: f32, c: f32, d: f32) -> f32:
    let normalized = t / d
    return -c * (math.sqrtf(1.0 - normalized * normalized) - 1.0) + b


def ease_circ_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    let normalized = t / d - 1.0
    return c * math.sqrtf(1.0 - normalized * normalized) + b


def ease_circ_in_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    var normalized = t / (d / 2.0)
    if normalized < 1.0:
        return -c / 2.0 * (math.sqrtf(1.0 - normalized * normalized) - 1.0) + b

    normalized -= 2.0
    return c / 2.0 * (math.sqrtf(1.0 - normalized * normalized) + 1.0) + b


def ease_cubic_in(t: f32, b: f32, c: f32, d: f32) -> f32:
    let normalized = t / d
    return c * normalized * normalized * normalized + b


def ease_cubic_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    let normalized = t / d - 1.0
    return c * (normalized * normalized * normalized + 1.0) + b


def ease_cubic_in_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    var normalized = t / (d / 2.0)
    if normalized < 1.0:
        return c / 2.0 * normalized * normalized * normalized + b

    normalized -= 2.0
    return c / 2.0 * (normalized * normalized * normalized + 2.0) + b


def ease_quad_in(t: f32, b: f32, c: f32, d: f32) -> f32:
    let normalized = t / d
    return c * normalized * normalized + b


def ease_quad_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    let normalized = t / d
    return -c * normalized * (normalized - 2.0) + b


def ease_quad_in_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    let normalized = t / (d / 2.0)
    if normalized < 1.0:
        return c / 2.0 * normalized * normalized + b

    return -c / 2.0 * ((normalized - 1.0) * (normalized - 3.0) - 1.0) + b


def ease_expo_in(t: f32, b: f32, c: f32, d: f32) -> f32:
    if t == 0.0:
        return b

    return c * pow2(10.0 * (t / d - 1.0)) + b


def ease_expo_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    if t == d:
        return b + c

    return c * (-pow2(-10.0 * t / d) + 1.0) + b


def ease_expo_in_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    if t == 0.0:
        return b
    if t == d:
        return b + c

    let normalized = t / (d / 2.0)
    if normalized < 1.0:
        return c / 2.0 * pow2(10.0 * (normalized - 1.0)) + b

    return c / 2.0 * (-pow2(-10.0 * (normalized - 1.0)) + 2.0) + b


def ease_back_in(t: f32, b: f32, c: f32, d: f32) -> f32:
    let overshoot: f32 = 1.70158
    let normalized = t / d
    return c * normalized * normalized * ((overshoot + 1.0) * normalized - overshoot) + b


def ease_back_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    let overshoot: f32 = 1.70158
    let normalized = t / d - 1.0
    return c * (normalized * normalized * ((overshoot + 1.0) * normalized + overshoot) + 1.0) + b


def ease_back_in_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    let scaled_overshoot: f32 = 1.70158 * 1.525
    var normalized = t / (d / 2.0)
    if normalized < 1.0:
        return c / 2.0 * (normalized * normalized * ((scaled_overshoot + 1.0) * normalized - scaled_overshoot)) + b

    normalized -= 2.0
    return c / 2.0 * (normalized * normalized * ((scaled_overshoot + 1.0) * normalized + scaled_overshoot) + 2.0) + b


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


def ease_bounce_in(t: f32, b: f32, c: f32, d: f32) -> f32:
    return c - ease_bounce_out(d - t, 0.0, c, d) + b


def ease_bounce_in_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    if t < d / 2.0:
        return ease_bounce_in(t * 2.0, 0.0, c, d) * 0.5 + b

    return ease_bounce_out(t * 2.0 - d, 0.0, c, d) * 0.5 + c * 0.5 + b


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


def ease_elastic_in_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    if t == 0.0:
        return b

    var normalized = t / (d / 2.0)
    if normalized == 2.0:
        return b + c

    let period = d * (0.3 * 1.5)
    let amplitude = c
    let shift = period / 4.0

    if normalized < 1.0:
        normalized -= 1.0
        let post_fix = amplitude * pow2(10.0 * normalized)
        return -0.5 * (post_fix * math.sinf((normalized * d - shift) * mt_math.tau / period)) + b

    normalized -= 1.0
    let post_fix = amplitude * pow2(-10.0 * normalized)
    return post_fix * math.sinf((normalized * d - shift) * mt_math.tau / period) * 0.5 + c + b


def restart_requested(bounded_t: bool, t: f32, d: f32) -> bool:
    if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT) or rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
        return true
    if rl.IsKeyPressed(rl.KeyboardKey.KEY_DOWN) or rl.IsKeyPressed(rl.KeyboardKey.KEY_UP):
        return true
    if rl.IsKeyPressed(rl.KeyboardKey.KEY_W) or rl.IsKeyPressed(rl.KeyboardKey.KEY_Q):
        return true
    if rl.IsKeyDown(rl.KeyboardKey.KEY_S) or rl.IsKeyDown(rl.KeyboardKey.KEY_A):
        return true
    if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE) or rl.IsKeyPressed(rl.KeyboardKey.KEY_T):
        return true

    return rl.IsKeyPressed(rl.KeyboardKey.KEY_ENTER) and bounded_t and t >= d


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var ball_position = rl.Vector2(x = 100.0, y = 100.0)
    let easings = array[EasingFunc, 29](
        EasingFunc(name = c"EaseLinearNone", callback = ease_linear_none),
        EasingFunc(name = c"EaseLinearIn", callback = ease_linear_in),
        EasingFunc(name = c"EaseLinearOut", callback = ease_linear_out),
        EasingFunc(name = c"EaseLinearInOut", callback = ease_linear_in_out),
        EasingFunc(name = c"EaseSineIn", callback = ease_sine_in),
        EasingFunc(name = c"EaseSineOut", callback = ease_sine_out),
        EasingFunc(name = c"EaseSineInOut", callback = ease_sine_in_out),
        EasingFunc(name = c"EaseCircIn", callback = ease_circ_in),
        EasingFunc(name = c"EaseCircOut", callback = ease_circ_out),
        EasingFunc(name = c"EaseCircInOut", callback = ease_circ_in_out),
        EasingFunc(name = c"EaseCubicIn", callback = ease_cubic_in),
        EasingFunc(name = c"EaseCubicOut", callback = ease_cubic_out),
        EasingFunc(name = c"EaseCubicInOut", callback = ease_cubic_in_out),
        EasingFunc(name = c"EaseQuadIn", callback = ease_quad_in),
        EasingFunc(name = c"EaseQuadOut", callback = ease_quad_out),
        EasingFunc(name = c"EaseQuadInOut", callback = ease_quad_in_out),
        EasingFunc(name = c"EaseExpoIn", callback = ease_expo_in),
        EasingFunc(name = c"EaseExpoOut", callback = ease_expo_out),
        EasingFunc(name = c"EaseExpoInOut", callback = ease_expo_in_out),
        EasingFunc(name = c"EaseBackIn", callback = ease_back_in),
        EasingFunc(name = c"EaseBackOut", callback = ease_back_out),
        EasingFunc(name = c"EaseBackInOut", callback = ease_back_in_out),
        EasingFunc(name = c"EaseBounceOut", callback = ease_bounce_out),
        EasingFunc(name = c"EaseBounceIn", callback = ease_bounce_in),
        EasingFunc(name = c"EaseBounceInOut", callback = ease_bounce_in_out),
        EasingFunc(name = c"EaseElasticIn", callback = ease_elastic_in),
        EasingFunc(name = c"EaseElasticOut", callback = ease_elastic_out),
        EasingFunc(name = c"EaseElasticInOut", callback = ease_elastic_in_out),
        EasingFunc(name = c"None", callback = no_ease),
    )

    var t: f32 = 0.0
    var d: f32 = 300.0
    var paused = true
    var bounded_t = true

    var easing_x = easing_none
    var easing_y = easing_none

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_T):
            bounded_t = not bounded_t

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            easing_x += 1
            if easing_x > easing_none:
                easing_x = 0
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
            if easing_x == 0:
                easing_x = easing_none
            else:
                easing_x -= 1

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_DOWN):
            easing_y += 1
            if easing_y > easing_none:
                easing_y = 0
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_UP):
            if easing_y == 0:
                easing_y = easing_none
            else:
                easing_y -= 1

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_W) and d < d_max - d_step:
            d += d_step
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_Q) and d > d_min + d_step:
            d -= d_step

        if rl.IsKeyDown(rl.KeyboardKey.KEY_S) and d < d_max - d_step_fine:
            d += d_step_fine
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_A) and d > d_min + d_step_fine:
            d -= d_step_fine

        if restart_requested(bounded_t, t, d):
            t = 0.0
            ball_position.x = 100.0
            ball_position.y = 100.0
            paused = true

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_ENTER):
            paused = not paused

        if not paused and ((bounded_t and t < d) or not bounded_t):
            ball_position.x = easings[easing_x].callback(t, 100.0, 530.0, d)
            ball_position.y = easings[easing_y].callback(t, 100.0, 230.0, d)
            t += 1.0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawText(rl.TextFormat(c"Easing x: %s", easings[easing_x].name), 20, font_size, font_size, rl.LIGHTGRAY)
        rl.DrawText(rl.TextFormat(c"Easing y: %s", easings[easing_y].name), 20, font_size * 2, font_size, rl.LIGHTGRAY)
        rl.DrawText(rl.TextFormat(c"t (%s) = %.2f d = %.2f", if bounded_t: c"b" else: c"u", t, d), 20, font_size * 3, font_size, rl.LIGHTGRAY)

        rl.DrawText(c"Use ENTER to play or pause movement, use SPACE to restart", 20, rl.GetScreenHeight() - font_size * 2, font_size, rl.LIGHTGRAY)
        rl.DrawText(c"Use Q and W or A and S keys to change duration", 20, rl.GetScreenHeight() - font_size * 3, font_size, rl.LIGHTGRAY)
        rl.DrawText(c"Use LEFT or RIGHT keys to choose easing for the x axis", 20, rl.GetScreenHeight() - font_size * 4, font_size, rl.LIGHTGRAY)
        rl.DrawText(c"Use UP or DOWN keys to choose easing for the y axis", 20, rl.GetScreenHeight() - font_size * 5, font_size, rl.LIGHTGRAY)

        rl.DrawCircleV(ball_position, 16.0, rl.MAROON)

    return 0
