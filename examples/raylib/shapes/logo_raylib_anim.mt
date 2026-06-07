import std.raylib as rl
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - logo raylib anim")
    defer rl.close_window()

    let logo_position_x = SCREEN_WIDTH / 2 - 128
    let logo_position_y = SCREEN_HEIGHT / 2 - 128

    var frames_counter = 0
    var letters_count = 0
    var top_side_rec_width = 16
    var left_side_rec_height = 16
    var bottom_side_rec_width = 16
    var right_side_rec_height = 16
    var state = 0
    var alpha: float = 1.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if state == 0:
            frames_counter += 1
            if frames_counter == 120:
                state = 1
                frames_counter = 0
        else if state == 1:
            top_side_rec_width += 4
            left_side_rec_height += 4
            if top_side_rec_width == 256:
                state = 2
        else if state == 2:
            bottom_side_rec_width += 4
            right_side_rec_height += 4
            if bottom_side_rec_width == 256:
                state = 3
        else if state == 3:
            frames_counter += 1
            if frames_counter >= 12:
                letters_count += 1
                frames_counter = 0

            if letters_count >= 10:
                alpha -= 0.02
                if alpha <= 0.0:
                    alpha = 0.0
                    state = 4
        else if state == 4:
            if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
                frames_counter = 0
                letters_count = 0
                top_side_rec_width = 16
                left_side_rec_height = 16
                bottom_side_rec_width = 16
                right_side_rec_height = 16
                alpha = 1.0
                state = 0

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        if state == 0:
            if ((frames_counter / 15) % 2) != 0:
                rl.draw_rectangle(logo_position_x, logo_position_y, 16, 16, rl.BLACK)
        else if state == 1:
            rl.draw_rectangle(logo_position_x, logo_position_y, top_side_rec_width, 16, rl.BLACK)
            rl.draw_rectangle(logo_position_x, logo_position_y, 16, left_side_rec_height, rl.BLACK)
        else if state == 2:
            rl.draw_rectangle(logo_position_x, logo_position_y, top_side_rec_width, 16, rl.BLACK)
            rl.draw_rectangle(logo_position_x, logo_position_y, 16, left_side_rec_height, rl.BLACK)
            rl.draw_rectangle(logo_position_x + 240, logo_position_y, 16, right_side_rec_height, rl.BLACK)
            rl.draw_rectangle(logo_position_x, logo_position_y + 240, bottom_side_rec_width, 16, rl.BLACK)
        else if state == 3:
            rl.draw_rectangle(logo_position_x, logo_position_y, top_side_rec_width, 16, rl.fade(rl.BLACK, alpha))
            rl.draw_rectangle(
                logo_position_x,
                logo_position_y + 16,
                16,
                left_side_rec_height - 32,
                rl.fade(rl.BLACK, alpha)
            )
            rl.draw_rectangle(
                logo_position_x + 240,
                logo_position_y + 16,
                16,
                right_side_rec_height - 32,
                rl.fade(rl.BLACK, alpha)
            )
            rl.draw_rectangle(
                logo_position_x,
                logo_position_y + 240,
                bottom_side_rec_width,
                16,
                rl.fade(rl.BLACK, alpha)
            )
            rl.draw_rectangle(
                rl.get_screen_width() / 2 - 112,
                rl.get_screen_height() / 2 - 112,
                224,
                224,
                rl.fade(rl.RAYWHITE, alpha)
            )
            rl.draw_text(
                text.cstr_as_str(rl.text_subtext("raylib", 0, letters_count)),
                rl.get_screen_width() / 2 - 44,
                rl.get_screen_height() / 2 + 48,
                50,
                rl.fade(rl.BLACK, alpha)
            )
        else if state == 4:
            rl.draw_text("[R] REPLAY", 340, 200, 20, rl.GRAY)

        rl.end_drawing()

    return 0
