import std.raylib.easing as ease
import std.raylib as rl
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const FONT_SIZE: int = 20
const D_STEP: float = 20.0
const D_STEP_FINE: float = 2.0
const D_MIN: float = 1.0
const D_MAX: float = 10000.0


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - easings testbed")
    defer rl.close_window()

    var ball_position = rl.Vector2(x = 100.0, y = 100.0)
    var t: float = 0.0
    var d: float = 300.0
    var paused = true
    var bounded_t = true
    var easing_x = ease.EASING_NONE
    var easing_y = ease.EASING_NONE

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_T):
            bounded_t = not bounded_t

        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            easing_x += 1
            if easing_x > ease.EASING_NONE:
                easing_x = 0
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            if easing_x == 0:
                easing_x = ease.EASING_NONE
            else:
                easing_x -= 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            easing_y += 1
            if easing_y > ease.EASING_NONE:
                easing_y = 0
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            if easing_y == 0:
                easing_y = ease.EASING_NONE
            else:
                easing_y -= 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_W) and d < (D_MAX - D_STEP):
            d += D_STEP
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_Q) and d > (D_MIN + D_STEP):
            d -= D_STEP

        if rl.is_key_down(rl.KeyboardKey.KEY_S) and d < (D_MAX - D_STEP_FINE):
            d += D_STEP_FINE
        else if rl.is_key_down(rl.KeyboardKey.KEY_A) and d > (D_MIN + D_STEP_FINE):
            d -= D_STEP_FINE

        if (
            rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE)
            or rl.is_key_pressed(rl.KeyboardKey.KEY_T)
            or rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT)
            or rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT)
            or rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN)
            or rl.is_key_pressed(rl.KeyboardKey.KEY_UP)
            or rl.is_key_pressed(rl.KeyboardKey.KEY_W)
            or rl.is_key_pressed(rl.KeyboardKey.KEY_Q)
            or rl.is_key_down(rl.KeyboardKey.KEY_S)
            or rl.is_key_down(rl.KeyboardKey.KEY_A)
            or (rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER) and bounded_t and t >= d)
        ):
            t = 0.0
            ball_position.x = 100.0
            ball_position.y = 100.0
            paused = true

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER):
            paused = not paused

        if not paused and ((bounded_t and t < d) or not bounded_t):
            ball_position.x = ease.by_kind(easing_x, t, 100.0, 530.0, d)
            ball_position.y = ease.by_kind(easing_y, t, 100.0, 230.0, d)
            t += 1.0

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text(
            text.cstr_as_str(rl.text_format("Easing x: %s", ease.kind_name(easing_x))),
            20,
            FONT_SIZE,
            FONT_SIZE,
            rl.LIGHTGRAY
        )
        rl.draw_text(
            text.cstr_as_str(rl.text_format("Easing y: %s", ease.kind_name(easing_y))),
            20,
            FONT_SIZE * 2,
            FONT_SIZE,
            rl.LIGHTGRAY
        )
        let time_mode = if bounded_t: "b" else: "u"
        rl.draw_text(
            text.cstr_as_str(rl.text_format("t (%s) = %.2f d = %.2f", time_mode, t, d)),
            20,
            FONT_SIZE * 3,
            FONT_SIZE,
            rl.LIGHTGRAY
        )

        rl.draw_text(
            "Use ENTER to play or pause movement, use SPACE to restart",
            20,
            rl.get_screen_height() - FONT_SIZE * 2,
            FONT_SIZE,
            rl.LIGHTGRAY
        )
        rl.draw_text(
            "Use Q and W or A and S keys to change duration",
            20,
            rl.get_screen_height() - FONT_SIZE * 3,
            FONT_SIZE,
            rl.LIGHTGRAY
        )
        rl.draw_text(
            "Use LEFT or RIGHT keys to choose easing for the x axis",
            20,
            rl.get_screen_height() - FONT_SIZE * 4,
            FONT_SIZE,
            rl.LIGHTGRAY
        )
        rl.draw_text(
            "Use UP or DOWN keys to choose easing for the y axis",
            20,
            rl.get_screen_height() - FONT_SIZE * 5,
            FONT_SIZE,
            rl.LIGHTGRAY
        )
        rl.draw_circle_v(ball_position, 16.0, rl.MAROON)
        rl.end_drawing()

    return 0
