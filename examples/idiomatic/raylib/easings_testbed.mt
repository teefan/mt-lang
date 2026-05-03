module examples.idiomatic.raylib.easings_testbed

import std.easing as ease
import std.raylib as rl

const font_size: i32 = 20
const d_step: f32 = 20.0
const d_step_fine: f32 = 2.0
const d_min: f32 = 1.0
const d_max: f32 = 10000.0
const screen_width: i32 = 800
const screen_height: i32 = 450
const easing_none: i32 = 28

struct EasingFunc:
    name: str
    callback: fn(time: f32, start: f32, change: f32, duration: f32) -> f32

def restart_requested(bounded_t: bool, t: f32, duration: f32) -> bool:
    if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT) or rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
        return true
    if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN) or rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
        return true
    if rl.is_key_pressed(rl.KeyboardKey.KEY_W) or rl.is_key_pressed(rl.KeyboardKey.KEY_Q):
        return true
    if rl.is_key_down(rl.KeyboardKey.KEY_S) or rl.is_key_down(rl.KeyboardKey.KEY_A):
        return true
    if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE) or rl.is_key_pressed(rl.KeyboardKey.KEY_T):
        return true

    return rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER) and bounded_t and t >= duration

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Easings Testbed")
    defer rl.close_window()

    var ball_position = rl.Vector2(x = 100.0, y = 100.0)
    let easings = array[EasingFunc, 29](
        EasingFunc(name = "EaseLinearNone", callback = ease.linear_none),
        EasingFunc(name = "EaseLinearIn", callback = ease.linear_in),
        EasingFunc(name = "EaseLinearOut", callback = ease.linear_out),
        EasingFunc(name = "EaseLinearInOut", callback = ease.linear_in_out),
        EasingFunc(name = "EaseSineIn", callback = ease.sine_in),
        EasingFunc(name = "EaseSineOut", callback = ease.sine_out),
        EasingFunc(name = "EaseSineInOut", callback = ease.sine_in_out),
        EasingFunc(name = "EaseCircIn", callback = ease.circ_in),
        EasingFunc(name = "EaseCircOut", callback = ease.circ_out),
        EasingFunc(name = "EaseCircInOut", callback = ease.circ_in_out),
        EasingFunc(name = "EaseCubicIn", callback = ease.cubic_in),
        EasingFunc(name = "EaseCubicOut", callback = ease.cubic_out),
        EasingFunc(name = "EaseCubicInOut", callback = ease.cubic_in_out),
        EasingFunc(name = "EaseQuadIn", callback = ease.quad_in),
        EasingFunc(name = "EaseQuadOut", callback = ease.quad_out),
        EasingFunc(name = "EaseQuadInOut", callback = ease.quad_in_out),
        EasingFunc(name = "EaseExpoIn", callback = ease.expo_in),
        EasingFunc(name = "EaseExpoOut", callback = ease.expo_out),
        EasingFunc(name = "EaseExpoInOut", callback = ease.expo_in_out),
        EasingFunc(name = "EaseBackIn", callback = ease.back_in),
        EasingFunc(name = "EaseBackOut", callback = ease.back_out),
        EasingFunc(name = "EaseBackInOut", callback = ease.back_in_out),
        EasingFunc(name = "EaseBounceOut", callback = ease.bounce_out),
        EasingFunc(name = "EaseBounceIn", callback = ease.bounce_in),
        EasingFunc(name = "EaseBounceInOut", callback = ease.bounce_in_out),
        EasingFunc(name = "EaseElasticIn", callback = ease.elastic_in),
        EasingFunc(name = "EaseElasticOut", callback = ease.elastic_out),
        EasingFunc(name = "EaseElasticInOut", callback = ease.elastic_in_out),
        EasingFunc(name = "None", callback = ease.none),
    )

    var t: f32 = 0.0
    var duration: f32 = 300.0
    var paused = true
    var bounded_t = true
    var easing_x = easing_none
    var easing_y = easing_none

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_T):
            bounded_t = not bounded_t

        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            easing_x += 1
            if easing_x > easing_none:
                easing_x = 0
        elif rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            if easing_x == 0:
                easing_x = easing_none
            else:
                easing_x -= 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            easing_y += 1
            if easing_y > easing_none:
                easing_y = 0
        elif rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            if easing_y == 0:
                easing_y = easing_none
            else:
                easing_y -= 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_W) and duration < d_max - d_step:
            duration += d_step
        elif rl.is_key_pressed(rl.KeyboardKey.KEY_Q) and duration > d_min + d_step:
            duration -= d_step

        if rl.is_key_down(rl.KeyboardKey.KEY_S) and duration < d_max - d_step_fine:
            duration += d_step_fine
        elif rl.is_key_down(rl.KeyboardKey.KEY_A) and duration > d_min + d_step_fine:
            duration -= d_step_fine

        if restart_requested(bounded_t, t, duration):
            t = 0.0
            ball_position.x = 100.0
            ball_position.y = 100.0
            paused = true

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER):
            paused = not paused

        if not paused and ((bounded_t and t < duration) or not bounded_t):
            ball_position.x = easings[easing_x].callback(t, 100.0, 530.0, duration)
            ball_position.y = easings[easing_y].callback(t, 100.0, 230.0, duration)
            t += 1.0

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text(rl.text_format_cstr("Easing x: %s", easings[easing_x].name), 20, font_size, font_size, rl.LIGHTGRAY)
        rl.draw_text(rl.text_format_cstr("Easing y: %s", easings[easing_y].name), 20, font_size * 2, font_size, rl.LIGHTGRAY)
        rl.draw_text(
            rl.text_format_cstr_f32_f32("t (%s) = %.2f d = %.2f", if bounded_t: "b" else: "u", t, duration),
            20,
            font_size * 3,
            font_size,
            rl.LIGHTGRAY,
        )

        rl.draw_text("Use ENTER to play or pause movement, use SPACE to restart", 20, rl.get_screen_height() - font_size * 2, font_size, rl.LIGHTGRAY)
        rl.draw_text("Use Q and W or A and S keys to change duration", 20, rl.get_screen_height() - font_size * 3, font_size, rl.LIGHTGRAY)
        rl.draw_text("Use LEFT or RIGHT keys to choose easing for the x axis", 20, rl.get_screen_height() - font_size * 4, font_size, rl.LIGHTGRAY)
        rl.draw_text("Use UP or DOWN keys to choose easing for the y axis", 20, rl.get_screen_height() - font_size * 5, font_size, rl.LIGHTGRAY)
        rl.draw_circle_v(ball_position, 16.0, rl.MAROON)

    return 0