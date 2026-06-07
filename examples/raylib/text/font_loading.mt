import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [text] example - font loading")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let msg = "!#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHI\nJKLMNOPQRSTUVWXYZ[]^_`abcdefghijklmn\nopqrstuvwxyz{|}~¿ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÐÑÒÓ\nÔÕÖ×ØÙÚÛÜÝÞßàáâãäåæçèéêëìíîïðñòóôõö÷\nøùúûüýþÿ"

    let font_bm = rl.load_font("pixantiqua.fnt")
    defer rl.unload_font(font_bm)
    let font_ttf = rl.load_font_ex("pixantiqua.ttf", 32, null, 250)
    defer rl.unload_font(font_ttf)

    rl.set_text_line_spacing(16)

    var use_ttf = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        use_ttf = rl.is_key_down(rl.KeyboardKey.KEY_SPACE)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text("Hold SPACE to use TTF generated font", 20, 20, 20, rl.LIGHTGRAY)

        if not use_ttf:
            rl.draw_text_ex(font_bm, msg, rl.Vector2(x = 20.0, y = 100.0), float<-font_bm.baseSize, 2.0, rl.MAROON)
            rl.draw_text("Using BMFont (Angelcode) imported", 20, rl.get_screen_height() - 30, 20, rl.GRAY)
        else:
            rl.draw_text_ex(font_ttf, msg, rl.Vector2(x = 20.0, y = 100.0), float<-font_ttf.baseSize, 2.0, rl.LIME)
            rl.draw_text("Using TTF font generated", 20, rl.get_screen_height() - 30, 20, rl.GRAY)

        rl.end_drawing()

    return 0
