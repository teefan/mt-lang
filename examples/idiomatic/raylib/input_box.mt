module examples.idiomatic.raylib.input_box

import std.raylib as rl

const max_input_chars: i32 = 9
const screen_width: i32 = 800
const screen_height: i32 = 450

def assign_input_text(display: ref[str_builder[32]], codepoints: array[i32, max_input_chars], letter_count: i32) -> void:
    value(display).clear()
    for index in range(0, letter_count):
        value(display).append(rl.codepoint_to_str(codepoints[index]))
    return

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Input Box")
    defer rl.close_window()

    var codepoints = zero[array[i32, max_input_chars]]()
    var display: str_builder[32]
    var letter_count = 0

    let text_box = rl.Rectangle(
        x = cast[f32](screen_width) / 2.0 - 100.0,
        y = 180.0,
        width = 225.0,
        height = 50.0,
    )

    var mouse_on_text = false
    var frames_counter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        mouse_on_text = rl.check_collision_point_rec(rl.get_mouse_position(), text_box)

        if mouse_on_text:
            rl.set_mouse_cursor(rl.MouseCursor.MOUSE_CURSOR_IBEAM)

            var key = rl.get_char_pressed()
            while key > 0:
                if key >= 32 and key <= 125 and letter_count < max_input_chars:
                    codepoints[letter_count] = key
                    letter_count += 1
                key = rl.get_char_pressed()

            if rl.is_key_pressed(rl.KeyboardKey.KEY_BACKSPACE) and letter_count > 0:
                letter_count -= 1
                codepoints[letter_count] = 0
        else:
            rl.set_mouse_cursor(rl.MouseCursor.MOUSE_CURSOR_DEFAULT)

        if mouse_on_text:
            frames_counter += 1
        else:
            frames_counter = 0

        assign_input_text(addr(display), codepoints, letter_count)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("PLACE MOUSE OVER INPUT BOX!", 240, 140, 20, rl.GRAY)

        rl.draw_rectangle_rec(text_box, rl.LIGHTGRAY)
        if mouse_on_text:
            rl.draw_rectangle_lines(cast[i32](text_box.x), cast[i32](text_box.y), cast[i32](text_box.width), cast[i32](text_box.height), rl.RED)
        else:
            rl.draw_rectangle_lines(cast[i32](text_box.x), cast[i32](text_box.y), cast[i32](text_box.width), cast[i32](text_box.height), rl.DARKGRAY)

        let display_text = display.as_cstr()
        rl.draw_text(display_text, cast[i32](text_box.x) + 5, cast[i32](text_box.y) + 8, 40, rl.MAROON)
        rl.draw_text(rl.text_format_i32_i32("INPUT CHARS: %i/%i", letter_count, max_input_chars), 315, 250, 20, rl.DARKGRAY)

        if mouse_on_text:
            if letter_count < max_input_chars:
                if ((frames_counter / 20) % 2) == 0:
                    rl.draw_text("_", cast[i32](text_box.x) + 8 + rl.measure_text(display_text, 40), cast[i32](text_box.y) + 12, 40, rl.MAROON)
            else:
                rl.draw_text("Press BACKSPACE to delete chars...", 230, 300, 20, rl.GRAY)

    return 0
