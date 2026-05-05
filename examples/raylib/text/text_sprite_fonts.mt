module examples.raylib.text.text_sprite_fonts

import std.c.raylib as rl

const max_fonts: int = 8
const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [text] example - sprite fonts"
const title_text: cstr = c"free sprite fonts included with raylib"
const font0_path: cstr = c"../resources/sprite_fonts/alagard.png"
const font1_path: cstr = c"../resources/sprite_fonts/pixelplay.png"
const font2_path: cstr = c"../resources/sprite_fonts/mecha.png"
const font3_path: cstr = c"../resources/sprite_fonts/setback.png"
const font4_path: cstr = c"../resources/sprite_fonts/romulus.png"
const font5_path: cstr = c"../resources/sprite_fonts/pixantiqua.png"
const font6_path: cstr = c"../resources/sprite_fonts/alpha_beta.png"
const font7_path: cstr = c"../resources/sprite_fonts/jupiter_crash.png"


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var fonts = zero[array[rl.Font, max_fonts]]
    fonts[0] = rl.LoadFont(font0_path)
    fonts[1] = rl.LoadFont(font1_path)
    fonts[2] = rl.LoadFont(font2_path)
    fonts[3] = rl.LoadFont(font3_path)
    fonts[4] = rl.LoadFont(font4_path)
    fonts[5] = rl.LoadFont(font5_path)
    fonts[6] = rl.LoadFont(font6_path)
    fonts[7] = rl.LoadFont(font7_path)
    defer:
        for index in 0..max_fonts:
            rl.UnloadFont(fonts[index])

    let messages = array[cstr, max_fonts](
        c"ALAGARD FONT designed by Hewett Tsoi",
        c"PIXELPLAY FONT designed by Aleksander Shevchuk",
        c"MECHA FONT designed by Captain Falcon",
        c"SETBACK FONT designed by Brian Kent (AEnigma)",
        c"ROMULUS FONT designed by Hewett Tsoi",
        c"PIXANTIQUA FONT designed by Gerhard Grossmann",
        c"ALPHA_BETA FONT designed by Brian Kent (AEnigma)",
        c"JUPITER_CRASH FONT designed by Brian Kent (AEnigma)",
    )
    let spacings = array[int, max_fonts](2, 4, 8, 4, 3, 4, 4, 1)
    var positions = zero[array[rl.Vector2, max_fonts]]

    for index in 0..max_fonts:
        positions[index].x = float<-screen_width / 2.0 - rl.MeasureTextEx(fonts[index], messages[index], float<-fonts[index].baseSize * 2.0, float<-spacings[index]).x / 2.0
        positions[index].y = 60.0 + float<-fonts[index].baseSize + 45.0 * float<-index

    positions[3].y += 8.0
    positions[4].y += 2.0
    positions[7].y -= 8.0

    let colors = array[rl.Color, max_fonts](rl.MAROON, rl.ORANGE, rl.DARKGREEN, rl.DARKBLUE, rl.DARKPURPLE, rl.LIME, rl.GOLD, rl.RED)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawText(title_text, 220, 20, 20, rl.DARKGRAY)
        rl.DrawLine(220, 50, 600, 50, rl.DARKGRAY)

        for index in 0..max_fonts:
            rl.DrawTextEx(fonts[index], messages[index], positions[index], float<-fonts[index].baseSize * 2.0, float<-spacings[index], colors[index])

    return 0
