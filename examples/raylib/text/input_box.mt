import std.raylib as rl
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_INPUT_CHARS: int = 9


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [text] example - input box")
    defer rl.close_window()

    var name: array[char, 10] = zero[array[char, 10]]
    var letter_count = 0
    let text_box = rl.Rectangle(x = float<-SCREEN_WIDTH / 2.0 - 100.0, y = 180.0, width = 225.0, height = 50.0)
    var mouse_on_text = false
    var frames_counter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        mouse_on_text = rl.check_collision_point_rec(rl.get_mouse_position(), text_box)

        if mouse_on_text:
            rl.set_mouse_cursor(rl.MouseCursor.MOUSE_CURSOR_IBEAM)

            var key = rl.get_char_pressed()
            while key > 0:
                if key >= 32 and key <= 125 and letter_count < MAX_INPUT_CHARS:
                    name[letter_count] = char<-key
                    letter_count += 1
                    name[letter_count] = zero[char]

                key = rl.get_char_pressed()

            if rl.is_key_pressed(rl.KeyboardKey.KEY_BACKSPACE):
                letter_count -= 1
                if letter_count < 0:
                    letter_count = 0
                name[letter_count] = zero[char]
        else:
            rl.set_mouse_cursor(rl.MouseCursor.MOUSE_CURSOR_DEFAULT)

        if mouse_on_text:
            frames_counter += 1
        else:
            frames_counter = 0

        let name_text = text.chars_as_str(ptr_of(name[0]))

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text("PLACE MOUSE OVER INPUT BOX!", 240, 140, 20, rl.GRAY)

        rl.draw_rectangle_rec(text_box, rl.LIGHTGRAY)
        if mouse_on_text:
            rl.draw_rectangle_lines(int<-text_box.x, int<-text_box.y, int<-text_box.width, int<-text_box.height, rl.RED)
        else:
            rl.draw_rectangle_lines(
                int<-text_box.x,
                int<-text_box.y,
                int<-text_box.width,
                int<-text_box.height,
                rl.DARKGRAY
            )

        let input_count_text = rl.text_format("INPUT CHARS: %i/%i", letter_count, MAX_INPUT_CHARS)
        rl.draw_text(name_text, int<-text_box.x + 5, int<-text_box.y + 8, 40, rl.MAROON)
        rl.draw_text(input_count_text, 315, 250, 20, rl.DARKGRAY)

        if mouse_on_text:
            if letter_count < MAX_INPUT_CHARS:
                if ((frames_counter / 20) % 2) == 0:
                    rl.draw_text(
                        "_",
                        int<-text_box.x + 8 + rl.measure_text(name_text, 40),
                        int<-text_box.y + 12,
                        40,
                        rl.MAROON
                    )
            else:
                rl.draw_text("Press BACKSPACE to delete chars...", 230, 300, 20, rl.GRAY)

        rl.end_drawing()

    return 0
