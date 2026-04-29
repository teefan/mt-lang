module examples.raylib.textures.textures_bunnymark

import std.c.raylib as rl
import std.mem.heap as heap

struct Bunny:
    position: rl.Vector2
    speed: rl.Vector2
    color: rl.Color

const max_bunnies: i32 = 80000
const max_batch_elements: i32 = 8192
const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [textures] example - bunnymark"
const bunny_path: cstr = c"../resources/raybunny.png"
const bunnies_format: cstr = c"bunnies: %i"
const draw_calls_format: cstr = c"batched draw calls: %i"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let tex_bunny = rl.LoadTexture(bunny_path)
    defer rl.UnloadTexture(tex_bunny)

    let bunnies = heap.must_alloc_zeroed[Bunny](cast[usize](max_bunnies))
    defer heap.release(bunnies)

    var bunnies_view = span[Bunny](data = bunnies, len = cast[usize](max_bunnies))
    var bunnies_count = 0
    var paused = false

    while not rl.WindowShouldClose():
        if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT):
            for index in range(0, 100):
                let _ = index
                if bunnies_count < max_bunnies:
                    bunnies_view[bunnies_count].position = rl.GetMousePosition()
                    bunnies_view[bunnies_count].speed.x = cast[f32](rl.GetRandomValue(-250, 250))
                    bunnies_view[bunnies_count].speed.y = cast[f32](rl.GetRandomValue(-250, 250))
                    bunnies_view[bunnies_count].color = rl.Color(
                        r = cast[u8](rl.GetRandomValue(50, 240)),
                        g = cast[u8](rl.GetRandomValue(80, 240)),
                        b = cast[u8](rl.GetRandomValue(100, 240)),
                        a = 255,
                    )
                    bunnies_count += 1

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_P):
            paused = not paused

        if not paused:
            let frame_time = rl.GetFrameTime()
            for index in range(0, bunnies_count):
                bunnies_view[index].position.x += bunnies_view[index].speed.x * frame_time
                bunnies_view[index].position.y += bunnies_view[index].speed.y * frame_time

                if bunnies_view[index].position.x + cast[f32](tex_bunny.width) / 2.0 > cast[f32](rl.GetScreenWidth()) or bunnies_view[index].position.x + cast[f32](tex_bunny.width) / 2.0 < 0.0:
                    bunnies_view[index].speed.x *= -1.0
                if bunnies_view[index].position.y + cast[f32](tex_bunny.height) / 2.0 > cast[f32](rl.GetScreenHeight()) or bunnies_view[index].position.y + cast[f32](tex_bunny.height) / 2.0 - 40.0 < 0.0:
                    bunnies_view[index].speed.y *= -1.0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        for index in range(0, bunnies_count):
            rl.DrawTexture(tex_bunny, cast[i32](bunnies_view[index].position.x), cast[i32](bunnies_view[index].position.y), bunnies_view[index].color)

        rl.DrawRectangle(0, 0, screen_width, 40, rl.BLACK)
        rl.DrawText(rl.TextFormat(bunnies_format, bunnies_count), 120, 10, 20, rl.GREEN)
        rl.DrawText(rl.TextFormat(draw_calls_format, 1 + bunnies_count / max_batch_elements), 320, 10, 20, rl.MAROON)
        rl.DrawFPS(10, 10)

    return 0
