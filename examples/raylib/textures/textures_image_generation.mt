module examples.raylib.textures.textures_image_generation

import std.c.raylib as rl

const num_textures: int = 9
const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [textures] example - image generation"
const cycle_message: cstr = c"MOUSE LEFT BUTTON to CYCLE PROCEDURAL TEXTURES"


def texture_label(texture_index: int) -> cstr:
    if texture_index == 0:
        return c"VERTICAL GRADIENT"
    elif texture_index == 1:
        return c"HORIZONTAL GRADIENT"
    elif texture_index == 2:
        return c"DIAGONAL GRADIENT"
    elif texture_index == 3:
        return c"RADIAL GRADIENT"
    elif texture_index == 4:
        return c"SQUARE GRADIENT"
    elif texture_index == 5:
        return c"CHECKED"
    elif texture_index == 6:
        return c"WHITE NOISE"
    elif texture_index == 7:
        return c"PERLIN NOISE"
    return c"CELLULAR"


def texture_label_color(texture_index: int) -> rl.Color:
    if texture_index <= 2:
        return rl.RAYWHITE
    elif texture_index <= 4:
        return rl.LIGHTGRAY
    elif texture_index == 5:
        return rl.RAYWHITE
    elif texture_index <= 7:
        return rl.RED
    return rl.RAYWHITE


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let vertical_gradient = rl.GenImageGradientLinear(screen_width, screen_height, 0, rl.RED, rl.BLUE)
    let horizontal_gradient = rl.GenImageGradientLinear(screen_width, screen_height, 90, rl.RED, rl.BLUE)
    let diagonal_gradient = rl.GenImageGradientLinear(screen_width, screen_height, 45, rl.RED, rl.BLUE)
    let radial_gradient = rl.GenImageGradientRadial(screen_width, screen_height, 0.0, rl.WHITE, rl.BLACK)
    let square_gradient = rl.GenImageGradientSquare(screen_width, screen_height, 0.0, rl.WHITE, rl.BLACK)
    let checked = rl.GenImageChecked(screen_width, screen_height, 32, 32, rl.RED, rl.BLUE)
    let white_noise = rl.GenImageWhiteNoise(screen_width, screen_height, 0.5)
    let perlin_noise = rl.GenImagePerlinNoise(screen_width, screen_height, 50, 50, 4.0)
    let cellular = rl.GenImageCellular(screen_width, screen_height, 32)

    var textures = zero[array[rl.Texture2D, num_textures]]
    defer:
        for texture_index in 0..num_textures:
            rl.UnloadTexture(textures[texture_index])

    textures[0] = rl.LoadTextureFromImage(vertical_gradient)
    textures[1] = rl.LoadTextureFromImage(horizontal_gradient)
    textures[2] = rl.LoadTextureFromImage(diagonal_gradient)
    textures[3] = rl.LoadTextureFromImage(radial_gradient)
    textures[4] = rl.LoadTextureFromImage(square_gradient)
    textures[5] = rl.LoadTextureFromImage(checked)
    textures[6] = rl.LoadTextureFromImage(white_noise)
    textures[7] = rl.LoadTextureFromImage(perlin_noise)
    textures[8] = rl.LoadTextureFromImage(cellular)

    rl.UnloadImage(vertical_gradient)
    rl.UnloadImage(horizontal_gradient)
    rl.UnloadImage(diagonal_gradient)
    rl.UnloadImage(radial_gradient)
    rl.UnloadImage(square_gradient)
    rl.UnloadImage(checked)
    rl.UnloadImage(white_noise)
    rl.UnloadImage(perlin_noise)
    rl.UnloadImage(cellular)

    var current_texture = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT) or rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            current_texture = (current_texture + 1) % num_textures

        rl.BeginDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawTexture(textures[current_texture], 0, 0, rl.WHITE)

        rl.DrawRectangle(30, 400, 325, 30, rl.Fade(rl.SKYBLUE, 0.5))
        rl.DrawRectangleLines(30, 400, 325, 30, rl.Fade(rl.WHITE, 0.5))
        rl.DrawText(cycle_message, 40, 410, 10, rl.WHITE)
        rl.DrawText(texture_label(current_texture), 540, 10, 20, texture_label_color(current_texture))

        rl.EndDrawing()

    return 0
