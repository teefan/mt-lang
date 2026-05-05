module examples.idiomatic.raylib.to_image

import std.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const image_path: str = "../../raylib/resources/raylib_logo.png"


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea Texture To Image")
    defer rl.close_window()

    var image = rl.load_image(image_path)
    var texture = rl.load_texture_from_image(image)
    rl.unload_image(image)

    image = rl.load_image_from_texture(texture)
    rl.unload_texture(texture)

    texture = rl.load_texture_from_image(image)
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
