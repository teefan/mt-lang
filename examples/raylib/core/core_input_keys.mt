module examples.raylib.core.core_input_keys

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - input keys"
const help_text: cstr = c"move the ball with arrow keys"
const ball_radius: f32 = 50.0
const ball_step: f32 = 2.0

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var ball_position = rl.Vector2(
        x = screen_width / 2.0,
        y = screen_height / 2.0,
    )

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT):
            ball_position.x += ball_step
        if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT):
            ball_position.x -= ball_step
        if rl.IsKeyDown(rl.KeyboardKey.KEY_UP):
            ball_position.y -= ball_step
        if rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN):
            ball_position.y += ball_step

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawText(help_text, 10, 10, 20, rl.DARKGRAY)
        rl.DrawCircleV(ball_position, ball_radius, rl.MAROON)

    return 0