module examples.raylib.textures.textures_srcrec_dstrec

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [textures] example - srcrec dstrec"
const scarfy_path: cstr = c"../resources/scarfy.png"
const credit_text: cstr = c"(c) Scarfy sprite by Eiden Marsal"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let scarfy = rl.LoadTexture(scarfy_path)
    defer rl.UnloadTexture(scarfy)

    let frame_width = scarfy.width / 6
    let frame_height = scarfy.height

    let source_rec = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = f32<-frame_width,
        height = f32<-frame_height,
    )
    let dest_rec = rl.Rectangle(
        x = screen_width / 2.0,
        y = screen_height / 2.0,
        width = frame_width * 2.0,
        height = frame_height * 2.0,
    )
    let origin = rl.Vector2(x = f32<-frame_width, y = f32<-frame_height)

    var rotation: f32 = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rotation += 1.0

        rl.BeginDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawTexturePro(scarfy, source_rec, dest_rec, origin, rotation, rl.WHITE)

        rl.DrawLine(i32<-dest_rec.x, 0, i32<-dest_rec.x, screen_height, rl.GRAY)
        rl.DrawLine(0, i32<-dest_rec.y, screen_width, i32<-dest_rec.y, rl.GRAY)
        rl.DrawText(credit_text, screen_width - 200, screen_height - 20, 10, rl.GRAY)

        rl.EndDrawing()

    return 0
