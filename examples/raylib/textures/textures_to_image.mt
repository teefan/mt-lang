module examples.raylib.textures.textures_to_image

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [textures] example - to image"
const image_path: cstr = c"../resources/raylib_logo.png"
const message_text: cstr = c"this IS a texture loaded from an image!"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var image = rl.LoadImage(image_path)
    var texture = rl.LoadTextureFromImage(image)
    rl.UnloadImage(image)

    image = rl.LoadImageFromTexture(texture)
    rl.UnloadTexture(texture)

    texture = rl.LoadTextureFromImage(image)
    rl.UnloadImage(image)
    defer rl.UnloadTexture(texture)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.BeginDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawTexture(texture, screen_width / 2 - texture.width / 2, screen_height / 2 - texture.height / 2, rl.WHITE)
        rl.DrawText(message_text, 300, 370, 10, rl.GRAY)

        rl.EndDrawing()

    return 0
