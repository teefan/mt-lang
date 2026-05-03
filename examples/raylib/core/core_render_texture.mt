module examples.raylib.core.core_render_texture

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - render texture"
const help_text: cstr = c"DRAWING BOUNCING BALL INSIDE RENDER TEXTURE!"
const render_texture_width: i32 = 300
const render_texture_height: i32 = 300
const ball_radius_limit: f32 = 20.0

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let target = rl.LoadRenderTexture(render_texture_width, render_texture_height)
    defer rl.UnloadRenderTexture(target)

    var ball_position = rl.Vector2(
        x = 0.5 * render_texture_width,
        y = 0.5 * render_texture_height,
    )
    var ball_speed = rl.Vector2(x = 5.0, y = 4.0)
    var rotation: f32 = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        ball_position.x += ball_speed.x
        ball_position.y += ball_speed.y

        if ball_position.x >= render_texture_width - ball_radius_limit or ball_position.x <= ball_radius_limit:
            ball_speed.x *= -1.0
        if ball_position.y >= render_texture_height - ball_radius_limit or ball_position.y <= ball_radius_limit:
            ball_speed.y *= -1.0

        rotation += 0.5

        rl.BeginTextureMode(target)
        rl.ClearBackground(rl.SKYBLUE)
        rl.DrawRectangle(0, 0, 20, 20, rl.RED)
        rl.DrawCircleV(ball_position, ball_radius_limit, rl.MAROON)
        rl.EndTextureMode()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawTexturePro(
            target.texture,
            rl.Rectangle(
                x = 0.0,
                y = 0.0,
                width = target.texture.width,
                height = -target.texture.height,
            ),
            rl.Rectangle(
                x = 0.5 * screen_width,
                y = 0.5 * screen_height,
                width = target.texture.width,
                height = target.texture.height,
            ),
            rl.Vector2(
                x = 0.5 * target.texture.width,
                y = 0.5 * target.texture.height,
            ),
            rotation,
            rl.WHITE,
        )
        rl.DrawText(help_text, 10, screen_height - 40, 20, rl.BLACK)
        rl.DrawFPS(10, 10)

    return 0