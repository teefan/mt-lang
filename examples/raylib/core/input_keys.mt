import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - input keys")
    defer rl.close_window()

    var ball_position = rl.Vector2(x = 400.0, y = 225.0)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT):
            ball_position.x += 2.0
        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT):
            ball_position.x -= 2.0
        if rl.is_key_down(rl.KeyboardKey.KEY_UP):
            ball_position.y -= 2.0
        if rl.is_key_down(rl.KeyboardKey.KEY_DOWN):
            ball_position.y += 2.0

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("move the ball with arrow keys", 10, 10, 20, rl.DARKGRAY)
        rl.draw_circle_v(ball_position, 50.0, rl.MAROON)
        rl.end_drawing()

    return 0