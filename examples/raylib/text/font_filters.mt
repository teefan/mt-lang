import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [text] example - font filters")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let msg = "Loaded Font"

    var font = rl.load_font_ex("KAISG.ttf", 96, null, 0)
    defer rl.unload_font(font)
    rl.gen_texture_mipmaps(font.texture)

    var font_size = float<-font.baseSize
    var font_position = rl.Vector2(x = 40.0, y = float<-SCREEN_HEIGHT / 2.0 - 80.0)
    var text_size = rl.Vector2(x = 0.0, y = 0.0)

    rl.set_texture_filter(font.texture, int<-rl.TextureFilter.TEXTURE_FILTER_POINT)
    var current_font_filter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        font_size += rl.get_mouse_wheel_move() * 4.0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            rl.set_texture_filter(font.texture, int<-rl.TextureFilter.TEXTURE_FILTER_POINT)
            current_font_filter = 0
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            rl.set_texture_filter(font.texture, int<-rl.TextureFilter.TEXTURE_FILTER_BILINEAR)
            current_font_filter = 1
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            rl.set_texture_filter(font.texture, int<-rl.TextureFilter.TEXTURE_FILTER_TRILINEAR)
            current_font_filter = 2

        text_size = rl.measure_text_ex(font, msg, font_size, 0.0)

        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT):
            font_position.x -= 10.0
        else if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT):
            font_position.x += 10.0

        if rl.is_file_dropped():
            let dropped_files = rl.load_dropped_files()
            defer rl.unload_dropped_files(dropped_files)

            if dropped_files.count > 0u:
                let dropped_path = unsafe: text.chars_as_str(read(dropped_files.paths))
                if rl.is_file_extension(dropped_path, ".ttf"):
                    rl.unload_font(font)
                    font = rl.load_font_ex(dropped_path, int<-font_size, null, 0)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text("Use mouse wheel to change font size", 20, 20, 10, rl.GRAY)
        rl.draw_text("Use KEY_RIGHT and KEY_LEFT to move text", 20, 40, 10, rl.GRAY)
        rl.draw_text("Use 1, 2, 3 to change texture filter", 20, 60, 10, rl.GRAY)
        rl.draw_text("Drop a new TTF font for dynamic loading", 20, 80, 10, rl.DARKGRAY)

        rl.draw_text_ex(font, msg, font_position, font_size, 0.0, rl.BLACK)

        rl.draw_rectangle(0, SCREEN_HEIGHT - 80, SCREEN_WIDTH, 80, rl.LIGHTGRAY)
        let font_size_text = rl.text_format("Font size: %02.02f", font_size)
        let text_size_text = rl.text_format("Text size: [%02.02f, %02.02f]", text_size.x, text_size.y)
        rl.draw_text(font_size_text, 20, SCREEN_HEIGHT - 50, 10, rl.DARKGRAY)
        rl.draw_text(text_size_text, 20, SCREEN_HEIGHT - 30, 10, rl.DARKGRAY)
        rl.draw_text("CURRENT TEXTURE FILTER:", 250, 400, 20, rl.GRAY)

        if current_font_filter == 0:
            rl.draw_text("POINT", 570, 400, 20, rl.BLACK)
        else if current_font_filter == 1:
            rl.draw_text("BILINEAR", 570, 400, 20, rl.BLACK)
        else:
            rl.draw_text("TRILINEAR", 570, 400, 20, rl.BLACK)

        rl.end_drawing()

    return 0
