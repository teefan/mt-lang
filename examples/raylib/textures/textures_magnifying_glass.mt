module examples.raylib.textures.textures_magnifying_glass

import std.c.raylib as rl
import std.c.rlgl as rlgl

const screen_width: i32 = 800
const screen_height: i32 = 450
const glass_size: i32 = 256
const glass_radius: f32 = 128.0
const window_title: cstr = c"raylib [textures] example - magnifying glass"
const bunny_path: cstr = c"../resources/raybunny.png"
const parrots_path: cstr = c"../resources/parrots.png"
const help_text: cstr = c"Use the magnifying glass to find hidden bunnies!"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let bunny = rl.LoadTexture(bunny_path)
    let parrots = rl.LoadTexture(parrots_path)

    var circle = rl.GenImageColor(glass_size, glass_size, rl.BLANK)
    rl.ImageDrawCircle(ptr_of(circle), 128, 128, 128, rl.WHITE)
    let mask = rl.LoadTextureFromImage(circle)
    rl.UnloadImage(circle)

    let magnified_world = rl.LoadRenderTexture(glass_size, glass_size)

    defer:
        rl.UnloadRenderTexture(magnified_world)
        rl.UnloadTexture(mask)
        rl.UnloadTexture(parrots)
        rl.UnloadTexture(bunny)

    var camera = zero[rl.Camera2D]()
    camera.zoom = 2.0
    camera.offset = rl.Vector2(x = glass_radius, y = glass_radius)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let mouse_pos = rl.GetMousePosition()
        camera.target = mouse_pos

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawTexture(parrots, 144, 33, rl.WHITE)
        rl.DrawText(help_text, 154, 6, 20, rl.BLACK)

        rl.BeginTextureMode(magnified_world)
        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode2D(camera)
        rl.DrawTexture(parrots, 144, 33, rl.WHITE)
        rl.DrawText(help_text, 154, 6, 20, rl.BLACK)

        rl.BeginBlendMode(rl.BlendMode.BLEND_MULTIPLIED)
        rl.DrawTexture(bunny, 250, 350, rl.WHITE)
        rl.DrawTexture(bunny, 500, 100, rl.WHITE)
        rl.DrawTexture(bunny, 420, 300, rl.WHITE)
        rl.DrawTexture(bunny, 650, 10, rl.WHITE)
        rl.EndBlendMode()
        rl.EndMode2D()

        rl.BeginBlendMode(rl.BlendMode.BLEND_CUSTOM_SEPARATE)
        rlgl.rlSetBlendFactorsSeparate(rlgl.RL_ZERO, rlgl.RL_ONE, rlgl.RL_ONE, rlgl.RL_ZERO, rlgl.RL_FUNC_ADD, rlgl.RL_FUNC_ADD)
        rl.DrawTexture(mask, 0, 0, rl.WHITE)
        rl.EndBlendMode()
        rl.EndTextureMode()

        rl.DrawTextureRec(
            magnified_world.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = f32<-glass_size, height = -f32<-glass_size),
            rl.Vector2(x = mouse_pos.x - glass_radius, y = mouse_pos.y - glass_radius),
            rl.WHITE,
        )

        rl.DrawRing(mouse_pos, 126.0, 130.0, 0.0, 360.0, 64, rl.BLACK)

        let rx = mouse_pos.x / f32<-screen_width
        let ry = mouse_pos.y / f32<-screen_width
        rl.DrawCircle(i32<-(mouse_pos.x - 64.0 * rx) - 32, i32<-(mouse_pos.y - 64.0 * ry) - 32, 4.0, rl.ColorAlpha(rl.WHITE, 0.5))

    return 0
