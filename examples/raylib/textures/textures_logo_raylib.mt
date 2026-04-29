module examples.raylib.textures.textures_logo_raylib

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [textures] example - logo raylib"
const texture_path: cstr = c"../resources/raylib_logo.png"
const message_text: cstr = c"this IS a texture!"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let texture = rl.LoadTexture(texture_path)
    defer rl.UnloadTexture(texture)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.BeginDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawTexture(texture, screen_width / 2 - texture.width / 2, screen_height / 2 - texture.height / 2, rl.WHITE)
        rl.DrawText(message_text, 360, 370, 10, rl.GRAY)

        rl.EndDrawing()

    return 0
