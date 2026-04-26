module examples.raylib.textures.textures_image_text

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [textures] example - image text"
const parrots_path: cstr = c"resources/parrots.png"
const font_path: cstr = c"resources/KAISG.ttf"
const title_text: cstr = c"[Parrots font drawing]"
const help_text: cstr = c"PRESS SPACE to SHOW FONT ATLAS USED"
const font_size: i32 = 64

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var parrots = rl.LoadImage(parrots_path)
    let font = rl.LoadFontEx(font_path, font_size, zero[ptr[i32]](), 0)
    defer rl.UnloadFont(font)

    rl.ImageDrawTextEx(raw(addr(parrots)), font, title_text, rl.Vector2(x = 20.0, y = 20.0), cast[f32](font.baseSize), 0.0, rl.RED)

    let texture = rl.LoadTextureFromImage(parrots)
    rl.UnloadImage(parrots)
    defer rl.UnloadTexture(texture)

    let position = rl.Vector2(
        x = screen_width / 2.0 - texture.width / 2.0,
        y = screen_height / 2.0 - texture.height / 2.0 - 20.0,
    )

    var show_font = false

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        show_font = rl.IsKeyDown(rl.KeyboardKey.KEY_SPACE)

        rl.BeginDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        if not show_font:
            rl.DrawTextureV(texture, position, rl.WHITE)
            rl.DrawTextEx(font, title_text, rl.Vector2(x = position.x + 20.0, y = position.y + 300.0), cast[f32](font.baseSize), 0.0, rl.WHITE)
        else:
            rl.DrawTexture(font.texture, screen_width / 2 - font.texture.width / 2, 50, rl.BLACK)

        rl.DrawText(help_text, 290, 420, 10, rl.DARKGRAY)

        rl.EndDrawing()

    return 0
