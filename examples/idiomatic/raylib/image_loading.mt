module examples.idiomatic.raylib.image_loading

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const image_path: str = "../../raylib/resources/raylib_logo.png"

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Image Loading")
    defer rl.close_window()

    let image = rl.load_image(image_path)
    let texture = rl.load_texture_from_image(image)
    rl.unload_image(image)
    defer rl.unload_texture(texture)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_texture(texture, screen_width / 2 - texture.width / 2, screen_height / 2 - texture.height / 2, rl.WHITE)
        rl.draw_text("this IS a texture loaded from an image!", 300, 370, 10, rl.GRAY)

    return 0