module examples.raylib.textures.textures_background_scrolling

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [textures] example - background scrolling"
const background_path: cstr = c"../resources/cyberpunk_street_background.png"
const midground_path: cstr = c"../resources/cyberpunk_street_midground.png"
const foreground_path: cstr = c"../resources/cyberpunk_street_foreground.png"
const background_scale: f32 = 2.0


def reset_scroll(scroll: f32, texture_width: i32) -> f32:
    if scroll <= -f32<-(texture_width * 2):
        return 0.0
    return scroll


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let background = rl.LoadTexture(background_path)
    let midground = rl.LoadTexture(midground_path)
    let foreground = rl.LoadTexture(foreground_path)
    defer:
        rl.UnloadTexture(foreground)
        rl.UnloadTexture(midground)
        rl.UnloadTexture(background)

    var scrolling_back: f32 = 0.0
    var scrolling_mid: f32 = 0.0
    var scrolling_fore: f32 = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        scrolling_back = reset_scroll(scrolling_back - 0.1, background.width)
        scrolling_mid = reset_scroll(scrolling_mid - 0.5, midground.width)
        scrolling_fore = reset_scroll(scrolling_fore - 1.0, foreground.width)

        rl.BeginDrawing()

        rl.ClearBackground(rl.GetColor(0x052c46ff))

        rl.DrawTextureEx(background, rl.Vector2(x = scrolling_back, y = 20.0), 0.0, background_scale, rl.WHITE)
        rl.DrawTextureEx(background, rl.Vector2(x = f32<-(background.width * 2) + scrolling_back, y = 20.0), 0.0, background_scale, rl.WHITE)

        rl.DrawTextureEx(midground, rl.Vector2(x = scrolling_mid, y = 20.0), 0.0, background_scale, rl.WHITE)
        rl.DrawTextureEx(midground, rl.Vector2(x = f32<-(midground.width * 2) + scrolling_mid, y = 20.0), 0.0, background_scale, rl.WHITE)

        rl.DrawTextureEx(foreground, rl.Vector2(x = scrolling_fore, y = 70.0), 0.0, background_scale, rl.WHITE)
        rl.DrawTextureEx(foreground, rl.Vector2(x = f32<-(foreground.width * 2) + scrolling_fore, y = 70.0), 0.0, background_scale, rl.WHITE)

        rl.DrawText(c"BACKGROUND SCROLLING & PARALLAX", 10, 10, 20, rl.RED)
        rl.DrawText(c"(c) Cyberpunk Street Environment by Luis Zuno (@ansimuz)", screen_width - 330, screen_height - 20, 10, rl.RAYWHITE)

        rl.EndDrawing()

    return 0
