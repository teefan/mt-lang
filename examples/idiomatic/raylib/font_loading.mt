module examples.idiomatic.raylib.font_loading

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const message: str = "!#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHI\nJKLMNOPQRSTUVWXYZ[]^_`abcdefghijklmn\nopqrstuvwxyz{|}~¿ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓ\nÔÕÖ×ØÙÚÛÜÝÞßàáâãäåæçèéêëìíîïðñòóôõö÷\nøùúûüýþÿ"
const font_bm_path: str = "../../raylib/text/resources/pixantiqua.fnt"
const font_ttf_path: str = "../../raylib/text/resources/pixantiqua.ttf"

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Font Loading")
    defer rl.close_window()

    let font_bm = rl.load_font(font_bm_path)
    defer rl.unload_font(font_bm)

    let font_ttf = rl.load_font_ex(font_ttf_path, 32, null, 250)
    defer rl.unload_font(font_ttf)

    rl.set_text_line_spacing(16)
    rl.set_target_fps(60)

    while not rl.window_should_close():
        let use_ttf = rl.is_key_down(rl.KeyboardKey.KEY_SPACE)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("Hold SPACE to use TTF generated font", 20, 20, 20, rl.LIGHTGRAY)

        if not use_ttf:
            rl.draw_text_ex(font_bm, message, rl.Vector2(x = 20.0, y = 100.0), cast[f32](font_bm.baseSize), 2.0, rl.MAROON)
            rl.draw_text("Using BMFont imported", 20, rl.get_screen_height() - 30, 20, rl.GRAY)
        else:
            rl.draw_text_ex(font_ttf, message, rl.Vector2(x = 20.0, y = 100.0), cast[f32](font_ttf.baseSize), 2.0, rl.LIME)
            rl.draw_text("Using TTF font generated", 20, rl.get_screen_height() - 30, 20, rl.GRAY)

    return 0
