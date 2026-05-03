module examples.raylib.shapes.shapes_bouncing_ball

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - bouncing ball"
const pause_text: cstr = c"PRESS SPACE to PAUSE BALL MOVEMENT"
const gravity_on_text: cstr = c"GRAVITY: ON (Press G to disable)"
const gravity_off_text: cstr = c"GRAVITY: OFF (Press G to enable)"
const paused_text: cstr = c"PAUSED"

def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var ball_position = rl.Vector2(x = rl.GetScreenWidth() / 2.0, y = rl.GetScreenHeight() / 2.0)
    var ball_speed = rl.Vector2(x = 5.0, y = 4.0)
    let ball_radius = 20
    let gravity: f32 = 0.2

    var use_gravity = true
    var pause = false
    var frames_counter = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_G):
            use_gravity = not use_gravity
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            pause = not pause

        if not pause:
            ball_position.x += ball_speed.x
            ball_position.y += ball_speed.y

            if use_gravity:
                ball_speed.y += gravity

            if ball_position.x >= rl.GetScreenWidth() - ball_radius or ball_position.x <= ball_radius:
                ball_speed.x *= -1.0
            if ball_position.y >= rl.GetScreenHeight() - ball_radius or ball_position.y <= ball_radius:
                ball_speed.y *= -0.95
        else:
            frames_counter += 1

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawCircleV(ball_position, ball_radius, rl.MAROON)
        rl.DrawText(pause_text, 10, rl.GetScreenHeight() - 25, 20, rl.LIGHTGRAY)

        if use_gravity:
            rl.DrawText(gravity_on_text, 10, rl.GetScreenHeight() - 50, 20, rl.DARKGREEN)
        else:
            rl.DrawText(gravity_off_text, 10, rl.GetScreenHeight() - 50, 20, rl.RED)

        if pause and (frames_counter / 30) % 2 == 1:
            rl.DrawText(paused_text, 350, 200, 30, rl.GRAY)

        rl.DrawFPS(10, 10)

    return 0