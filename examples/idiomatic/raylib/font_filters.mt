module examples.idiomatic.raylib.font_filters

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const font_path: str = "../../raylib/text/resources/KAISG.ttf"
const message: str = "Loaded Font"

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Font Filters")
    defer rl.close_window()

    var font = rl.load_font_ex(font_path, 96, null, 0)
    defer rl.unload_font(font)

    rl.gen_texture_mipmaps(inout font.texture)

    var font_size = cast[f32](font.baseSize)
    var font_position = rl.Vector2(x = 40.0, y = cast[f32](screen_height) / 2.0 - 80.0)
    var text_size = rl.Vector2(x = 0.0, y = 0.0)

    rl.set_texture_filter(font.texture, rl.TextureFilter.TEXTURE_FILTER_POINT)
    var current_font_filter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        font_size += rl.get_mouse_wheel_move() * 4.0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            rl.set_texture_filter(font.texture, rl.TextureFilter.TEXTURE_FILTER_POINT)
            current_font_filter = 0
        elif rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            rl.set_texture_filter(font.texture, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)
            current_font_filter = 1
        elif rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            rl.set_texture_filter(font.texture, rl.TextureFilter.TEXTURE_FILTER_TRILINEAR)
            current_font_filter = 2

        text_size = rl.measure_text_ex(font, message, font_size, 0.0)

        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT):
            font_position.x -= 10.0
        elif rl.is_key_down(rl.KeyboardKey.KEY_RIGHT):
            font_position.x += 10.0

        if rl.is_file_dropped():
            let dropped_files = rl.load_dropped_files()
            defer rl.unload_dropped_files(dropped_files)

            if dropped_files.count > 0:
                let dropped_path = rl.file_path_at(dropped_files, 0)
                if rl.is_file_extension(dropped_path, ".ttf"):
                    rl.unload_font(font)
                    font = rl.load_font_ex(dropped_path, cast[i32](font_size), null, 0)
                    rl.gen_texture_mipmaps(inout font.texture)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        rl.draw_text("Use mouse wheel to change font size", 20, 20, 10, rl.GRAY)
        rl.draw_text("Use KEY_RIGHT and KEY_LEFT to move text", 20, 40, 10, rl.GRAY)
        rl.draw_text("Use 1, 2, 3 to change texture filter", 20, 60, 10, rl.GRAY)
        rl.draw_text("Drop a new TTF font for dynamic loading", 20, 80, 10, rl.DARKGRAY)

        rl.draw_text_ex(font, message, font_position, font_size, 0.0, rl.BLACK)

        rl.draw_rectangle(0, screen_height - 80, screen_width, 80, rl.LIGHTGRAY)
        rl.draw_text(rl.text_format_f32("Font size: %02.02f", font_size), 20, screen_height - 50, 10, rl.DARKGRAY)
        rl.draw_text(rl.text_format_f32_f32("Text size: [%02.02f, %02.02f]", text_size.x, text_size.y), 20, screen_height - 30, 10, rl.DARKGRAY)
        rl.draw_text("CURRENT TEXTURE FILTER:", 250, 400, 20, rl.GRAY)

        if current_font_filter == 0:
            rl.draw_text("POINT", 570, 400, 20, rl.BLACK)
        elif current_font_filter == 1:
            rl.draw_text("BILINEAR", 570, 400, 20, rl.BLACK)
        elif current_font_filter == 2:
            rl.draw_text("TRILINEAR", 570, 400, 20, rl.BLACK)

    return 0
