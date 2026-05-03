module examples.raylib.textures.textures_image_rotate

import std.c.raylib as rl

const num_textures: i32 = 3
const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [textures] example - image rotate"
const logo_path: cstr = c"../resources/raylib_logo.png"
const help_text: cstr = c"Press LEFT MOUSE BUTTON to rotate the image clockwise"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var image_45 = rl.LoadImage(logo_path)
    var image_90 = rl.LoadImage(logo_path)
    var image_neg_90 = rl.LoadImage(logo_path)

    rl.ImageRotate(ptr_of(ref_of(image_45)), 45)
    rl.ImageRotate(ptr_of(ref_of(image_90)), 90)
    rl.ImageRotate(ptr_of(ref_of(image_neg_90)), -90)

    var textures = zero[array[rl.Texture2D, num_textures]]()
    defer:
        for texture_index in range(0, num_textures):
            rl.UnloadTexture(textures[texture_index])

    textures[0] = rl.LoadTextureFromImage(image_45)
    textures[1] = rl.LoadTextureFromImage(image_90)
    textures[2] = rl.LoadTextureFromImage(image_neg_90)

    rl.UnloadImage(image_45)
    rl.UnloadImage(image_90)
    rl.UnloadImage(image_neg_90)

    var current_texture = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT) or rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            current_texture = (current_texture + 1) % num_textures

        rl.BeginDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawTexture(textures[current_texture], screen_width / 2 - textures[current_texture].width / 2, screen_height / 2 - textures[current_texture].height / 2, rl.WHITE)
        rl.DrawText(help_text, 250, 420, 10, rl.DARKGRAY)

        rl.EndDrawing()

    return 0