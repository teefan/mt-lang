module examples.raylib.textures.textures_bunnymark

import std.c.raylib as rl
import std.mem.heap as heap
import std.span as sp

struct Bunny:
    position: rl.Vector2
    speed: rl.Vector2
    color: rl.Color

const max_bunnies: int = 80000
const max_batch_elements: int = 8192
const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [textures] example - bunnymark"
const bunny_path: cstr = c"../resources/raybunny.png"
const bunnies_format: cstr = c"bunnies: %i"
const draw_calls_format: cstr = c"batched draw calls: %i"


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let tex_bunny = rl.LoadTexture(bunny_path)
    defer rl.UnloadTexture(tex_bunny)

    let bunnies = heap.must_alloc_zeroed[Bunny](ptr_uint<-max_bunnies)
    defer heap.release(bunnies)

    var bunnies_view = sp.from_ptr[Bunny](bunnies, ptr_uint<-max_bunnies)
    var bunnies_count = 0
    var paused = false

    while not rl.WindowShouldClose():
        if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT):
            for index in 0..100:
                let _ = index
                if bunnies_count < max_bunnies:
                    bunnies_view[bunnies_count].position = rl.GetMousePosition()
                    bunnies_view[bunnies_count].speed.x = float<-rl.GetRandomValue(-250, 250)
                    bunnies_view[bunnies_count].speed.y = float<-rl.GetRandomValue(-250, 250)
                    bunnies_view[bunnies_count].color = rl.Color(
                        r = ubyte<-rl.GetRandomValue(50, 240),
                        g = ubyte<-rl.GetRandomValue(80, 240),
                        b = ubyte<-rl.GetRandomValue(100, 240),
                        a = 255,
                    )
                    bunnies_count += 1

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_P):
            paused = not paused

        if not paused:
            let frame_time = rl.GetFrameTime()
            for index in 0..bunnies_count:
                bunnies_view[index].position.x += bunnies_view[index].speed.x * frame_time
                bunnies_view[index].position.y += bunnies_view[index].speed.y * frame_time

                if bunnies_view[index].position.x + float<-tex_bunny.width / 2.0 > float<-rl.GetScreenWidth() or bunnies_view[index].position.x + float<-tex_bunny.width / 2.0 < 0.0:
                    bunnies_view[index].speed.x *= -1.0
                if bunnies_view[index].position.y + float<-tex_bunny.height / 2.0 > float<-rl.GetScreenHeight() or bunnies_view[index].position.y + float<-tex_bunny.height / 2.0 - 40.0 < 0.0:
                    bunnies_view[index].speed.y *= -1.0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        for index in 0..bunnies_count:
            rl.DrawTexture(tex_bunny, int<-bunnies_view[index].position.x, int<-bunnies_view[index].position.y, bunnies_view[index].color)

        rl.DrawRectangle(0, 0, screen_width, 40, rl.BLACK)
        rl.DrawText(rl.TextFormat(bunnies_format, bunnies_count), 120, 10, 20, rl.GREEN)
        rl.DrawText(rl.TextFormat(draw_calls_format, 1 + bunnies_count / max_batch_elements), 320, 10, 20, rl.MAROON)
        rl.DrawFPS(10, 10)

    return 0
