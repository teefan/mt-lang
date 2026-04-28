module examples.idiomatic.raylib.codepoints_loading

import std.mem.heap as heap
import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const text: str = "いろはにほへと　ちりぬるを\nわかよたれそ　つねならむ\nうゐのおくやま　けふこえて\nあさきゆめみし　ゑひもせす"
const font_path: str = "../../raylib/text/resources/DotGothic16-Regular.ttf"

def copy_unique_codepoints(codepoints: span[i32], output: span[i32]) -> i32:
    var output_count = 0

    for source_index in range(0, cast[i32](codepoints.len)):
        let codepoint = codepoints[source_index]
        var found = false

        for output_index in range(0, output_count):
            if output[output_index] == codepoint:
                found = true

        if not found:
            output[output_count] = codepoint
            output_count += 1

    return output_count

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Codepoints Loading")
    defer rl.close_window()

    let codepoints = rl.load_codepoints(text)
    defer rl.unload_codepoint_list(codepoints)

    let unique_storage = heap.must_alloc_zeroed[i32](cast[usize](codepoints.count))
    defer heap.release(unique_storage)

    let unique_buffer = span[i32](data = unique_storage, len = cast[usize](codepoints.count))
    let unique_count = copy_unique_codepoints(rl.codepoints_span(codepoints), unique_buffer)
    let unique_codepoints = span[i32](data = unique_storage, len = cast[usize](unique_count))

    let font = rl.load_font_ex_span(font_path, 36, unique_codepoints)
    defer rl.unload_font(font)

    rl.set_texture_filter(font.texture, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)
    rl.set_text_line_spacing(20)

    var show_font_atlas = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            show_font_atlas = not show_font_atlas

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        rl.draw_rectangle(0, 0, rl.get_screen_width(), 70, rl.BLACK)
        rl.draw_text(rl.text_format_i32("Total codepoints contained in provided text: %i", codepoints.count), 10, 10, 20, rl.GREEN)
        rl.draw_text(rl.text_format_i32("Total codepoints required for font atlas (duplicates excluded): %i", unique_count), 10, 40, 20, rl.GREEN)

        if show_font_atlas:
            rl.draw_texture(font.texture, 150, 100, rl.BLACK)
            rl.draw_rectangle_lines(150, 100, font.texture.width, font.texture.height, rl.BLACK)
        else:
            rl.draw_text_ex(font, text, rl.Vector2(x = 160.0, y = 110.0), 48.0, 5.0, rl.BLACK)

        rl.draw_text("Press SPACE to toggle font atlas view!", 10, rl.get_screen_height() - 30, 20, rl.GRAY)

    return 0
