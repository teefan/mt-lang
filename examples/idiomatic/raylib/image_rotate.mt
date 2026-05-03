module examples.idiomatic.raylib.image_rotate

import std.raylib as rl

const num_textures: i32 = 3
const screen_width: i32 = 800
const screen_height: i32 = 450
const logo_path: str = "../../raylib/resources/raylib_logo.png"

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Image Rotate")
    defer rl.close_window()

    var image_45 = rl.load_image(logo_path)
    var image_90 = rl.load_image(logo_path)
    var image_neg_90 = rl.load_image(logo_path)

    rl.image_rotate(inout image_45, 45)
    rl.image_rotate(inout image_90, 90)
    rl.image_rotate(inout image_neg_90, -90)

    var textures = zero[array[rl.Texture2D, 3]]()
    defer:
        for texture_index in range(0, num_textures):
            rl.unload_texture(textures[texture_index])

    textures[0] = rl.load_texture_from_image(image_45)
    textures[1] = rl.load_texture_from_image(image_90)
    textures[2] = rl.load_texture_from_image(image_neg_90)

    rl.unload_image(image_45)
    rl.unload_image(image_90)
    rl.unload_image(image_neg_90)

    var current_texture = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT) or rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            current_texture = (current_texture + 1) % num_textures

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_texture(textures[current_texture], screen_width / 2 - textures[current_texture].width / 2, screen_height / 2 - textures[current_texture].height / 2, rl.WHITE)
        rl.draw_text("Press LEFT MOUSE BUTTON to rotate the image clockwise", 250, 420, 10, rl.DARKGRAY)

    return 0