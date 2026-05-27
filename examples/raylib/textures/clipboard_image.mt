import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_TEXTURE_COLLECTION: int = 20


struct TextureCollection:
    texture: rl.Texture2D
    position: rl.Vector2


function unload_collection(collection: ref[array[TextureCollection, MAX_TEXTURE_COLLECTION]]) -> void:
    var index = 0
    while index < MAX_TEXTURE_COLLECTION:
        if rl.is_texture_valid(read(collection)[index].texture):
            rl.unload_texture(read(collection)[index].texture)
            read(collection)[index].texture = zero[rl.Texture2D]
        index += 1


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - clipboard image")
    defer rl.close_window()

    var collection: array[TextureCollection, MAX_TEXTURE_COLLECTION] = zero[array[TextureCollection, MAX_TEXTURE_COLLECTION]]
    defer unload_collection(ref_of(collection))

    var current_collection_index = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            unload_collection(ref_of(collection))
            current_collection_index = 0

        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT_CONTROL) and
           rl.is_key_pressed(rl.KeyboardKey.KEY_V) and
           current_collection_index < MAX_TEXTURE_COLLECTION:
            let image = rl.get_clipboard_image()

            if rl.is_image_valid(image):
                collection[current_collection_index].texture = rl.load_texture_from_image(image)
                collection[current_collection_index].position = rl.get_mouse_position()
                current_collection_index += 1
                rl.unload_image(image)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        var index = 0
        while index < current_collection_index:
            if rl.is_texture_valid(collection[index].texture):
                rl.draw_texture_pro(
                    collection[index].texture,
                    rl.Rectangle(
                        x = 0.0,
                        y = 0.0,
                        width = float<-collection[index].texture.width,
                        height = float<-collection[index].texture.height,
                    ),
                    rl.Rectangle(
                        x = collection[index].position.x,
                        y = collection[index].position.y,
                        width = float<-collection[index].texture.width,
                        height = float<-collection[index].texture.height,
                    ),
                    rl.Vector2(
                        x = float<-collection[index].texture.width * 0.5,
                        y = float<-collection[index].texture.height * 0.5,
                    ),
                    0.0,
                    rl.WHITE,
                )
            index += 1

        rl.draw_rectangle(0, 0, SCREEN_WIDTH, 40, rl.BLACK)
        rl.draw_text("Clipboard Image - Ctrl+V to Paste and R to Reset ", 120, 10, 20, rl.LIGHTGRAY)

        rl.end_drawing()

    return 0
