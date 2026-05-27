import std.raylib as rl
import std.raymath as rm


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const WORD_COUNT: int = 11


function alignment_amount(kind: int) -> float:
    if kind == 0:
        return 0.0
    if kind == 1:
        return 0.5
    return 1.0


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [text] example - words alignment")
    defer rl.close_window()

    let text_container_rect = rl.Rectangle(
        x = float<-SCREEN_WIDTH / 2.0 - float<-SCREEN_WIDTH / 4.0,
        y = float<-SCREEN_HEIGHT / 2.0 - float<-SCREEN_HEIGHT / 3.0,
        width = float<-SCREEN_WIDTH / 2.0,
        height = float<-SCREEN_HEIGHT * 2.0 / 3.0,
    )

    let text_align_name_h = array[str, 3]("Left", "Centre", "Right")
    let text_align_name_v = array[str, 3]("Top", "Middle", "Bottom")
    let words = array[str, WORD_COUNT]("raylib", "is", "a", "simple", "and", "easy-to-use", "library", "to", "enjoy", "videogames", "programming")

    var word_index = 0
    let font_size = 40
    let font = rl.get_font_default()
    var h_align = 1
    var v_align = 1

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT) and h_align > 0:
            h_align -= 1
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT) and h_align < 2:
            h_align += 1
        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP) and v_align > 0:
            v_align -= 1
        if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN) and v_align < 2:
            v_align += 1

        word_index = (int<-rl.get_time()) % WORD_COUNT
        let current_word = words[word_index]
        let text_size = rl.measure_text_ex(font, current_word, float<-font_size, float<-font_size * 0.1)
        let text_pos = rl.Vector2(
            x = text_container_rect.x + rm.lerp(0.0, text_container_rect.width - text_size.x, alignment_amount(h_align)),
            y = text_container_rect.y + rm.lerp(0.0, text_container_rect.height - text_size.y, alignment_amount(v_align)),
        )

        rl.begin_drawing()
        rl.clear_background(rl.DARKBLUE)

        rl.draw_text("Use Arrow Keys to change the text alignment", 20, 20, 20, rl.LIGHTGRAY)
        rl.draw_text(rl.text_format("Alignment: Horizontal = %s, Vertical = %s", text_align_name_h[h_align], text_align_name_v[v_align]), 20, 40, 20, rl.LIGHTGRAY)
        rl.draw_rectangle_rec(text_container_rect, rl.BLUE)
        rl.draw_text_ex(font, current_word, text_pos, float<-font_size, float<-font_size * 0.1, rl.RAYWHITE)

        rl.end_drawing()

    return 0
