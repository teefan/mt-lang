module examples.raylib.textures.textures_image_loading

import std.c.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [textures] example - image loading"
const image_path: cstr = c"../resources/raylib_logo.png"
const message_text: cstr = c"this IS a texture loaded from an image!"


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let image = rl.LoadImage(image_path)
    let texture = rl.LoadTextureFromImage(image)
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
