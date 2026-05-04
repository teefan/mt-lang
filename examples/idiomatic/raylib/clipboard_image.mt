module examples.idiomatic.raylib.clipboard_image

import std.raylib as rl

struct TextureCollection:
    texture: rl.Texture2D
    position: rl.Vector2

const max_texture_collection: i32 = 20
const screen_width: i32 = 800
const screen_height: i32 = 450


def unload_collection(collection: array[TextureCollection, 20], count: i32) -> void:
    for index in 0..count:
        if rl.is_texture_valid(collection[index].texture):
            rl.unload_texture(collection[index].texture)
    return


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Clipboard Image")
    defer rl.close_window()

    var collection = zero[array[TextureCollection, 20]]
    var current_collection_index = 0
    var show_clipboard_error = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            unload_collection(collection, current_collection_index)
            collection = zero[array[TextureCollection, 20]]
            current_collection_index = 0
            show_clipboard_error = false

        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT_CONTROL) and rl.is_key_pressed(rl.KeyboardKey.KEY_V) and current_collection_index < max_texture_collection:
            let image = rl.get_clipboard_image()

            if rl.is_image_valid(image):
                collection[current_collection_index].texture = rl.load_texture_from_image(image)
                collection[current_collection_index].position = rl.get_mouse_position()
                current_collection_index += 1
                rl.unload_image(image)
                show_clipboard_error = false
            else:
                show_clipboard_error = true

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        for index in 0..current_collection_index:
            let texture = collection[index].texture
            let position = collection[index].position
            if rl.is_texture_valid(texture):
                rl.draw_texture_pro(
                    texture,
                    rl.Rectangle(x = 0.0, y = 0.0, width = f32<-texture.width, height = f32<-texture.height),
                    rl.Rectangle(x = position.x, y = position.y, width = f32<-texture.width, height = f32<-texture.height),
                    rl.Vector2(x = f32<-texture.width * 0.5, y = f32<-texture.height * 0.5),
                    0.0,
                    rl.WHITE,
                )

        rl.draw_rectangle(0, 0, screen_width, 40, rl.BLACK)
        rl.draw_text("Clipboard Image - Ctrl+V to Paste and R to Reset ", 120, 10, 20, rl.LIGHTGRAY)

        if show_clipboard_error:
            rl.draw_text("IMAGE: Could not retrieve image from clipboard", 160, screen_height - 35, 20, rl.RED)

    unload_collection(collection, current_collection_index)

    return 0
