import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const NUM_TEXTURES: int = 3


function selected_texture(
    current_texture: int,
    texture45: rl.Texture2D,
    texture90: rl.Texture2D,
    texture_neg90: rl.Texture2D
) -> rl.Texture2D:
    if current_texture == 0:
        return texture45
    if current_texture == 1:
        return texture90
    return texture_neg90


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - image rotate")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var image45 = rl.load_image("raylib_logo.png")
    defer rl.unload_image(image45)
    var image90 = rl.load_image("raylib_logo.png")
    defer rl.unload_image(image90)
    var image_neg90 = rl.load_image("raylib_logo.png")
    defer rl.unload_image(image_neg90)

    rl.image_rotate(image45, 45)
    rl.image_rotate(image90, 90)
    rl.image_rotate(image_neg90, -90)

    let texture45 = rl.load_texture_from_image(image45)
    defer rl.unload_texture(texture45)
    let texture90 = rl.load_texture_from_image(image90)
    defer rl.unload_texture(texture90)
    let texture_neg90 = rl.load_texture_from_image(image_neg90)
    defer rl.unload_texture(texture_neg90)

    var current_texture = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT) or rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            current_texture = (current_texture + 1) % NUM_TEXTURES

        let texture = selected_texture(current_texture, texture45, texture90, texture_neg90)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_texture(texture, SCREEN_WIDTH / 2 - texture.width / 2, SCREEN_HEIGHT / 2 - texture.height / 2, rl.WHITE)
        rl.draw_text("Press LEFT MOUSE BUTTON to rotate the image clockwise", 250, 420, 10, rl.DARKGRAY)

        rl.end_drawing()

    return 0
