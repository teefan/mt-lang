module examples.raylib.textures.textures_blend_modes

import std.c.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [textures] example - blend modes"
const background_path: cstr = c"../resources/cyberpunk_street_background.png"
const foreground_path: cstr = c"../resources/cyberpunk_street_foreground.png"
const blend_count_max: int = 4
const help_text: cstr = c"Press SPACE to change blend modes."
const credit_text: cstr = c"(c) Cyberpunk Street Environment by Luis Zuno (@ansimuz)"


def blend_label(blend_mode: int) -> cstr:
    if blend_mode == rl.BlendMode.BLEND_ALPHA:
        return c"Current: BLEND_ALPHA"
    elif blend_mode == rl.BlendMode.BLEND_ADDITIVE:
        return c"Current: BLEND_ADDITIVE"
    elif blend_mode == rl.BlendMode.BLEND_MULTIPLIED:
        return c"Current: BLEND_MULTIPLIED"
    return c"Current: BLEND_ADD_COLORS"


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let background_image = rl.LoadImage(background_path)
    let background_texture = rl.LoadTextureFromImage(background_image)
    rl.UnloadImage(background_image)

    let foreground_image = rl.LoadImage(foreground_path)
    let foreground_texture = rl.LoadTextureFromImage(foreground_image)
    rl.UnloadImage(foreground_image)

    defer:
        rl.UnloadTexture(foreground_texture)
        rl.UnloadTexture(background_texture)

    var blend_mode: int = rl.BlendMode.BLEND_ALPHA

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            if blend_mode >= blend_count_max - 1:
                blend_mode = 0
            else:
                blend_mode += 1

        rl.BeginDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawTexture(background_texture, screen_width / 2 - background_texture.width / 2, screen_height / 2 - background_texture.height / 2, rl.WHITE)

        rl.BeginBlendMode(blend_mode)
        rl.DrawTexture(foreground_texture, screen_width / 2 - foreground_texture.width / 2, screen_height / 2 - foreground_texture.height / 2, rl.WHITE)
        rl.EndBlendMode()

        rl.DrawText(help_text, 310, 350, 10, rl.GRAY)
        rl.DrawText(blend_label(blend_mode), screen_width / 2 - 60, 370, 10, rl.GRAY)
        rl.DrawText(credit_text, screen_width - 330, screen_height - 20, 10, rl.GRAY)

        rl.EndDrawing()

    return 0
