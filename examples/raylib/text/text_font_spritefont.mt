module examples.raylib.text.text_font_spritefont

import std.c.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [text] example - font spritefont"
const msg1: cstr = c"THIS IS A custom SPRITE FONT..."
const msg2: cstr = c"...and this is ANOTHER CUSTOM font..."
const msg3: cstr = c"...and a THIRD one! GREAT! :D"
const font1_path: cstr = c"../resources/custom_mecha.png"
const font2_path: cstr = c"../resources/custom_alagard.png"
const font3_path: cstr = c"../resources/custom_jupiter_crash.png"


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let font1 = rl.LoadFont(font1_path)
    defer rl.UnloadFont(font1)

    let font2 = rl.LoadFont(font2_path)
    defer rl.UnloadFont(font2)

    let font3 = rl.LoadFont(font3_path)
    defer rl.UnloadFont(font3)

    let font_position1 = rl.Vector2(
        x = float<-screen_width / 2.0 - rl.MeasureTextEx(font1, msg1, float<-font1.baseSize, -3.0).x / 2.0,
        y = float<-screen_height / 2.0 - float<-font1.baseSize / 2.0 - 80.0,
    )
    let font_position2 = rl.Vector2(
        x = float<-screen_width / 2.0 - rl.MeasureTextEx(font2, msg2, float<-font2.baseSize, -2.0).x / 2.0,
        y = float<-screen_height / 2.0 - float<-font2.baseSize / 2.0 - 10.0,
    )
    let font_position3 = rl.Vector2(
        x = float<-screen_width / 2.0 - rl.MeasureTextEx(font3, msg3, float<-font3.baseSize, 2.0).x / 2.0,
        y = float<-screen_height / 2.0 - float<-font3.baseSize / 2.0 + 50.0,
    )

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawTextEx(font1, msg1, font_position1, float<-font1.baseSize, -3.0, rl.WHITE)
        rl.DrawTextEx(font2, msg2, font_position2, float<-font2.baseSize, -2.0, rl.WHITE)
        rl.DrawTextEx(font3, msg3, font_position3, float<-font3.baseSize, 2.0, rl.WHITE)

    return 0
