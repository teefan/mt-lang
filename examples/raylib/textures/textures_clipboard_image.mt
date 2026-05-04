module examples.raylib.textures.textures_clipboard_image

import std.c.raylib as rl

struct TextureCollection:
    texture: rl.Texture2D
    position: rl.Vector2

const max_texture_collection: i32 = 20
const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [textures] example - clipboard image"
const help_text: cstr = c"Clipboard Image - Ctrl+V to Paste and R to Reset "
const clipboard_error_text: cstr = c"IMAGE: Could not retrieve image from clipboard"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var collection = zero[array[TextureCollection, 20]]
    var current_collection_index = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_R):
            for index in 0..max_texture_collection:
                rl.UnloadTexture(collection[index].texture)

            current_collection_index = 0

        if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT_CONTROL) and rl.IsKeyPressed(rl.KeyboardKey.KEY_V) and current_collection_index < max_texture_collection:
            let image = rl.GetClipboardImage()

            if rl.IsImageValid(image):
                collection[current_collection_index].texture = rl.LoadTextureFromImage(image)
                collection[current_collection_index].position = rl.GetMousePosition()
                current_collection_index += 1
                rl.UnloadImage(image)
            else:
                rl.TraceLog(rl.TraceLogLevel.LOG_INFO, clipboard_error_text)

        rl.BeginDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        for index in 0..current_collection_index:
            let texture = collection[index].texture
            let position = collection[index].position
            if rl.IsTextureValid(texture):
                rl.DrawTexturePro(
                    texture,
                    rl.Rectangle(x = 0.0, y = 0.0, width = f32<-texture.width, height = f32<-texture.height),
                    rl.Rectangle(x = position.x, y = position.y, width = f32<-texture.width, height = f32<-texture.height),
                    rl.Vector2(x = f32<-texture.width * 0.5, y = f32<-texture.height * 0.5),
                    0.0,
                    rl.WHITE,
                )

        rl.DrawRectangle(0, 0, screen_width, 40, rl.BLACK)
        rl.DrawText(help_text, 120, 10, 20, rl.LIGHTGRAY)

        rl.EndDrawing()

    for index in 0..max_texture_collection:
        rl.UnloadTexture(collection[index].texture)

    return 0
