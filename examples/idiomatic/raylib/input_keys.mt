module examples.idiomatic.raylib.input_keys

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const ball_radius: f32 = 50.0
const ball_step: f32 = 2.0

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Input Keys")
    defer rl.close_window()

    var ball_position = rl.Vector2(
        x = screen_width / 2.0,
        y = screen_height / 2.0,
    )

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT):
            ball_position.x += ball_step
        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT):
            ball_position.x -= ball_step
        if rl.is_key_down(rl.KeyboardKey.KEY_UP):
            ball_position.y -= ball_step
        if rl.is_key_down(rl.KeyboardKey.KEY_DOWN):
            ball_position.y += ball_step

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("move the ball with arrow keys", 10, 10, 20, rl.DARKGRAY)
        rl.draw_circle_v(ball_position, ball_radius, rl.MAROON)

    return 0