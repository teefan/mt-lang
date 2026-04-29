module examples.raylib.textures.textures_image_channel

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [textures] example - image channel"
const fudesumi_path: cstr = c"../resources/fudesumi.png"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let fudesumi_image = rl.LoadImage(fudesumi_path)

    var image_alpha = rl.ImageFromChannel(fudesumi_image, 3)
    rl.ImageAlphaMask(raw(addr(image_alpha)), image_alpha)

    var image_red = rl.ImageFromChannel(fudesumi_image, 0)
    rl.ImageAlphaMask(raw(addr(image_red)), image_alpha)

    var image_green = rl.ImageFromChannel(fudesumi_image, 1)
    rl.ImageAlphaMask(raw(addr(image_green)), image_alpha)

    var image_blue = rl.ImageFromChannel(fudesumi_image, 2)
    rl.ImageAlphaMask(raw(addr(image_blue)), image_alpha)

    let background_image = rl.GenImageChecked(screen_width, screen_height, screen_width / 20, screen_height / 20, rl.ORANGE, rl.YELLOW)

    let fudesumi_texture = rl.LoadTextureFromImage(fudesumi_image)
    let texture_alpha = rl.LoadTextureFromImage(image_alpha)
    let texture_red = rl.LoadTextureFromImage(image_red)
    let texture_green = rl.LoadTextureFromImage(image_green)
    let texture_blue = rl.LoadTextureFromImage(image_blue)
    let background_texture = rl.LoadTextureFromImage(background_image)

    rl.UnloadImage(fudesumi_image)
    rl.UnloadImage(image_alpha)
    rl.UnloadImage(image_red)
    rl.UnloadImage(image_green)
    rl.UnloadImage(image_blue)
    rl.UnloadImage(background_image)

    defer:
        rl.UnloadTexture(background_texture)
        rl.UnloadTexture(fudesumi_texture)
        rl.UnloadTexture(texture_red)
        rl.UnloadTexture(texture_green)
        rl.UnloadTexture(texture_blue)
        rl.UnloadTexture(texture_alpha)

    let fudesumi_rec = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = cast[f32](fudesumi_texture.width),
        height = cast[f32](fudesumi_texture.height),
    )
    let fudesumi_pos = rl.Rectangle(
        x = 50.0,
        y = 10.0,
        width = cast[f32](fudesumi_texture.width) * 0.8,
        height = cast[f32](fudesumi_texture.height) * 0.8,
    )
    let red_pos = rl.Rectangle(x = 410.0, y = 10.0, width = fudesumi_pos.width / 2.0, height = fudesumi_pos.height / 2.0)
    let green_pos = rl.Rectangle(x = 600.0, y = 10.0, width = fudesumi_pos.width / 2.0, height = fudesumi_pos.height / 2.0)
    let blue_pos = rl.Rectangle(x = 410.0, y = 230.0, width = fudesumi_pos.width / 2.0, height = fudesumi_pos.height / 2.0)
    let alpha_pos = rl.Rectangle(x = 600.0, y = 230.0, width = fudesumi_pos.width / 2.0, height = fudesumi_pos.height / 2.0)
    let origin = rl.Vector2(x = 0.0, y = 0.0)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.BeginDrawing()

        rl.DrawTexture(background_texture, 0, 0, rl.WHITE)
        rl.DrawTexturePro(fudesumi_texture, fudesumi_rec, fudesumi_pos, origin, 0.0, rl.WHITE)
        rl.DrawTexturePro(texture_red, fudesumi_rec, red_pos, origin, 0.0, rl.RED)
        rl.DrawTexturePro(texture_green, fudesumi_rec, green_pos, origin, 0.0, rl.GREEN)
        rl.DrawTexturePro(texture_blue, fudesumi_rec, blue_pos, origin, 0.0, rl.BLUE)
        rl.DrawTexturePro(texture_alpha, fudesumi_rec, alpha_pos, origin, 0.0, rl.WHITE)

        rl.EndDrawing()

    return 0
