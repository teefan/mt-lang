module examples.raylib.core.core_window_letterbox

import std.c.raylib as rl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const game_screen_width: i32 = 640
const game_screen_height: i32 = 480
const bar_count: i32 = 10
const window_title: cstr = c"raylib [core] example - window letterbox"
const help_text: cstr = c"If executed inside a window,\nyou can resize the window,\nand see the screen scaling!"

def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_WINDOW_RESIZABLE | rl.ConfigFlags.FLAG_VSYNC_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()
    rl.SetWindowMinSize(320, 240)

    let target = rl.LoadRenderTexture(game_screen_width, game_screen_height)
    defer rl.UnloadRenderTexture(target)
    rl.SetTextureFilter(target.texture, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)

    var colors = zero[array[rl.Color, 10]]()
    var color_index = 0
    while color_index < bar_count:
        colors[color_index] = rl.Color(
            r = rl.GetRandomValue(100, 250),
            g = rl.GetRandomValue(50, 150),
            b = rl.GetRandomValue(10, 100),
            a = 255,
        )
        color_index += 1

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let width_scale: f32 = f32<-rl.GetScreenWidth() / game_screen_width
        let height_scale: f32 = f32<-rl.GetScreenHeight() / game_screen_height
        var scale = width_scale
        if height_scale < scale:
            scale = height_scale

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            color_index = 0
            while color_index < bar_count:
                colors[color_index] = rl.Color(
                    r = rl.GetRandomValue(100, 250),
                    g = rl.GetRandomValue(50, 150),
                    b = rl.GetRandomValue(10, 100),
                    a = 255,
                )
                color_index += 1

        let scaled_game_width = game_screen_width * scale
        let scaled_game_height = game_screen_height * scale
        let offset_x: f32 = (rl.GetScreenWidth() - scaled_game_width) * 0.5
        let offset_y: f32 = (rl.GetScreenHeight() - scaled_game_height) * 0.5

        let mouse = rl.GetMousePosition()
        var virtual_mouse = rm.Vector2.zero()
        virtual_mouse.x = (mouse.x - offset_x) / scale
        virtual_mouse.y = (mouse.y - offset_y) / scale
        virtual_mouse = virtual_mouse.clamp(
            rm.Vector2.zero(),
            rl.Vector2(x = game_screen_width, y = game_screen_height),
        )

        rl.BeginTextureMode(target)
        rl.ClearBackground(rl.RAYWHITE)

        let stripe_height = game_screen_height / bar_count
        color_index = 0
        while color_index < bar_count:
            rl.DrawRectangle(0, stripe_height * color_index, game_screen_width, stripe_height, colors[color_index])
            color_index += 1

        rl.DrawText(help_text, 10, 25, 20, rl.WHITE)
        rl.DrawText(rl.TextFormat(c"Default Mouse: [%i , %i]", i32<-mouse.x, i32<-mouse.y), 350, 25, 20, rl.GREEN)
        rl.DrawText(rl.TextFormat(c"Virtual Mouse: [%i , %i]", i32<-virtual_mouse.x, i32<-virtual_mouse.y), 350, 55, 20, rl.YELLOW)

        rl.EndTextureMode()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)
        rl.DrawTexturePro(
            target.texture,
            rl.Rectangle(
                x = 0.0,
                y = 0.0,
                width = target.texture.width,
                height = -target.texture.height,
            ),
            rl.Rectangle(
                x = offset_x,
                y = offset_y,
                width = scaled_game_width,
                height = scaled_game_height,
            ),
            rm.Vector2.zero(),
            0.0,
            rl.WHITE,
        )

    return 0