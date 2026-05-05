module examples.raylib.textures.textures_image_drawing

import std.c.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [textures] example - image drawing"
const cat_path: cstr = c"../resources/cat.png"
const parrots_path: cstr = c"../resources/parrots.png"
const font_path: cstr = c"../resources/custom_jupiter_crash.png"
const line_one_text: cstr = c"We are drawing only one texture from various images composed!"
const line_two_text: cstr = c"Source images have been cropped, scaled, flipped and copied one over the other."
const title_text: cstr = c"PARROTS & CAT"


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var cat = rl.LoadImage(cat_path)
    rl.ImageCrop(ptr_of(cat), rl.Rectangle(x = 100.0, y = 10.0, width = 280.0, height = 380.0))
    rl.ImageFlipHorizontal(ptr_of(cat))
    rl.ImageResize(ptr_of(cat), 150, 200)

    var parrots = rl.LoadImage(parrots_path)

    rl.ImageDraw(
        ptr_of(parrots),
        cat,
        rl.Rectangle(x = 0.0, y = 0.0, width = float<-cat.width, height = float<-cat.height),
        rl.Rectangle(x = 30.0, y = 40.0, width = float<-cat.width * 1.5, height = float<-cat.height * 1.5),
        rl.WHITE,
    )
    rl.ImageCrop(ptr_of(parrots), rl.Rectangle(x = 0.0, y = 50.0, width = float<-parrots.width, height = float<-parrots.height - 100.0))

    rl.ImageDrawPixel(ptr_of(parrots), 10, 10, rl.RAYWHITE)
    rl.ImageDrawCircleLines(ptr_of(parrots), 10, 10, 5, rl.RAYWHITE)
    rl.ImageDrawRectangle(ptr_of(parrots), 5, 20, 10, 10, rl.RAYWHITE)

    rl.UnloadImage(cat)

    let font = rl.LoadFont(font_path)
    rl.ImageDrawTextEx(ptr_of(parrots), font, title_text, rl.Vector2(x = 300.0, y = 230.0), float<-font.baseSize, -2.0, rl.WHITE)
    rl.UnloadFont(font)

    let texture = rl.LoadTextureFromImage(parrots)
    rl.UnloadImage(parrots)
    defer rl.UnloadTexture(texture)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.BeginDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawTexture(texture, screen_width / 2 - texture.width / 2, screen_height / 2 - texture.height / 2 - 40, rl.WHITE)
        rl.DrawRectangleLines(screen_width / 2 - texture.width / 2, screen_height / 2 - texture.height / 2 - 40, texture.width, texture.height, rl.DARKGRAY)
        rl.DrawText(line_one_text, 240, 350, 10, rl.DARKGRAY)
        rl.DrawText(line_two_text, 190, 370, 10, rl.DARKGRAY)

        rl.EndDrawing()

    return 0
