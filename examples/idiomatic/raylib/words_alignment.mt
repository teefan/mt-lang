module examples.idiomatic.raylib.words_alignment

import std.raylib as rl
import std.raylib.math as rm

enum TextAlignment: i32
    TEXT_ALIGN_LEFT = 0
    TEXT_ALIGN_TOP = 0
    TEXT_ALIGN_CENTRE = 1
    TEXT_ALIGN_MIDDLE = 1
    TEXT_ALIGN_RIGHT = 2
    TEXT_ALIGN_BOTTOM = 2

const screen_width: i32 = 800
const screen_height: i32 = 450
const words_source: str = "raylib is a simple and easy-to-use library to enjoy videogames programming"

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Words Alignment")
    defer rl.close_window()

    var text_container_rect = rl.Rectangle(
        x = cast[f32](screen_width) / 2.0 - cast[f32](screen_width) / 4.0,
        y = cast[f32](screen_height) / 2.0 - cast[f32](screen_height) / 3.0,
        width = cast[f32](screen_width) / 2.0,
        height = cast[f32](screen_height) * 2.0 / 3.0,
    )

    let text_align_name_h = array[str, 3]("Left", "Centre", "Right")
    let text_align_name_v = array[str, 3]("Top", "Middle", "Bottom")

    var word_index = 0
    let words = rl.text_split(words_source, cast[char](32))

    let font_size = 40
    let font = rl.get_font_default()

    var h_align = TextAlignment.TEXT_ALIGN_CENTRE
    var v_align = TextAlignment.TEXT_ALIGN_MIDDLE

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            if h_align > TextAlignment.TEXT_ALIGN_LEFT:
                h_align = cast[TextAlignment](cast[i32](h_align) - 1)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            h_align = cast[TextAlignment](cast[i32](h_align) + 1)
            if h_align > TextAlignment.TEXT_ALIGN_RIGHT:
                h_align = TextAlignment.TEXT_ALIGN_RIGHT

        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            if v_align > TextAlignment.TEXT_ALIGN_TOP:
                v_align = cast[TextAlignment](cast[i32](v_align) - 1)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            v_align = cast[TextAlignment](cast[i32](v_align) + 1)
            if v_align > TextAlignment.TEXT_ALIGN_BOTTOM:
                v_align = TextAlignment.TEXT_ALIGN_BOTTOM

        if words.count > 0:
            word_index = cast[i32](rl.get_time()) % words.count
        else:
            word_index = 0

        let current_word = rl.text_split_at(words, word_index)
        let text_size = rl.measure_text_ex(font, current_word, cast[f32](font_size), cast[f32](font_size) * 0.1)
        let text_pos = rl.Vector2(
            x = text_container_rect.x + rm.lerp(0.0, text_container_rect.width - text_size.x, cast[f32](h_align) * 0.5),
            y = text_container_rect.y + rm.lerp(0.0, text_container_rect.height - text_size.y, cast[f32](v_align) * 0.5),
        )

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.DARKBLUE)
        rl.draw_text("Use Arrow Keys to change the text alignment", 20, 20, 20, rl.LIGHTGRAY)
        rl.draw_text(
            rl.text_format_cstr_cstr("Alignment: Horizontal = %s, Vertical = %s", text_align_name_h[cast[i32](h_align)], text_align_name_v[cast[i32](v_align)]),
            20,
            40,
            20,
            rl.LIGHTGRAY,
        )
        rl.draw_rectangle_rec(text_container_rect, rl.BLUE)
        rl.draw_text_ex(font, current_word, text_pos, cast[f32](font_size), cast[f32](font_size) * 0.1, rl.RAYWHITE)

    return 0
