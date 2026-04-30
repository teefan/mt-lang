module examples.idiomatic.raylib.image_drawing

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const cat_path: str = "../../raylib/resources/cat.png"
const parrots_path: str = "../../raylib/resources/parrots.png"
const font_path: str = "../../raylib/resources/custom_jupiter_crash.png"

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Image Drawing")
    defer rl.close_window()

    var cat = rl.load_image(cat_path)
    rl.image_crop(inout cat, rl.Rectangle(x = 100.0, y = 10.0, width = 280.0, height = 380.0))
    rl.image_flip_horizontal(inout cat)
    rl.image_resize(inout cat, 150, 200)

    var parrots = rl.load_image(parrots_path)

    rl.image_draw(
        inout parrots,
        cat,
        rl.Rectangle(x = 0.0, y = 0.0, width = f32<-cat.width, height = f32<-cat.height),
        rl.Rectangle(x = 30.0, y = 40.0, width = f32<-cat.width * 1.5, height = f32<-cat.height * 1.5),
        rl.WHITE,
    )
    rl.image_crop(inout parrots, rl.Rectangle(x = 0.0, y = 50.0, width = f32<-parrots.width, height = f32<-parrots.height - 100.0))

    rl.image_draw_pixel(inout parrots, 10, 10, rl.RAYWHITE)
    rl.image_draw_circle_lines(inout parrots, 10, 10, 5, rl.RAYWHITE)
    rl.image_draw_rectangle(inout parrots, 5, 20, 10, 10, rl.RAYWHITE)

    rl.unload_image(cat)

    let font = rl.load_font(font_path)
    rl.image_draw_text_ex(inout parrots, font, "PARROTS & CAT", rl.Vector2(x = 300.0, y = 230.0), f32<-font.baseSize, -2.0, rl.WHITE)
    rl.unload_font(font)

    let texture = rl.load_texture_from_image(parrots)
    rl.unload_image(parrots)
    defer rl.unload_texture(texture)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_texture(texture, screen_width / 2 - texture.width / 2, screen_height / 2 - texture.height / 2 - 40, rl.WHITE)
        rl.draw_rectangle_lines(screen_width / 2 - texture.width / 2, screen_height / 2 - texture.height / 2 - 40, texture.width, texture.height, rl.DARKGRAY)
        rl.draw_text("We are drawing only one texture from various images composed!", 240, 350, 10, rl.DARKGRAY)
        rl.draw_text("Source images have been cropped, scaled, flipped and copied one over the other.", 190, 370, 10, rl.DARKGRAY)

    return 0
