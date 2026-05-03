module examples.idiomatic.raylib.image_text

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const parrots_path: str = "../../raylib/resources/parrots.png"
const font_path: str = "../../raylib/resources/KAISG.ttf"
const font_size: i32 = 64

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Image Text")
    defer rl.close_window()

    var parrots = rl.load_image(parrots_path)
    let font = rl.load_font_ex(font_path, font_size, null, 0)
    defer rl.unload_font(font)

    rl.image_draw_text_ex(inout parrots, font, "[Parrots font drawing]", rl.Vector2(x = 20.0, y = 20.0), f32<-font.baseSize, 0.0, rl.RED)

    let texture = rl.load_texture_from_image(parrots)
    rl.unload_image(parrots)
    defer rl.unload_texture(texture)

    let position = rl.Vector2(
        x = f32<-screen_width / 2.0 - f32<-texture.width / 2.0,
        y = f32<-screen_height / 2.0 - f32<-texture.height / 2.0 - 20.0,
    )

    var show_font = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        show_font = rl.is_key_down(rl.KeyboardKey.KEY_SPACE)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        if not show_font:
            rl.draw_texture_v(texture, position, rl.WHITE)
            rl.draw_text_ex(font, "[Parrots font drawing]", rl.Vector2(x = position.x + 20.0, y = position.y + 300.0), f32<-font.baseSize, 0.0, rl.WHITE)
        else:
            rl.draw_texture(font.texture, screen_width / 2 - font.texture.width / 2, 50, rl.BLACK)

        rl.draw_text("PRESS SPACE to SHOW FONT ATLAS USED", 290, 420, 10, rl.DARKGRAY)

    return 0