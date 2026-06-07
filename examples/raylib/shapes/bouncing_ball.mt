import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - bouncing ball")
    defer rl.close_window()

    var ball_position = rl.Vector2(x = float<-rl.get_screen_width() / 2.0, y = float<-rl.get_screen_height() / 2.0)
    var ball_speed = rl.Vector2(x = 5.0, y = 4.0)
    let ball_radius = 20
    let gravity: float = 0.2
    var use_gravity = true
    var pause = false
    var frames_counter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_G):
            use_gravity = not use_gravity
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            pause = not pause

        if not pause:
            ball_position.x += ball_speed.x
            ball_position.y += ball_speed.y

            if use_gravity:
                ball_speed.y += gravity

            if ball_position.x >= float<-(rl.get_screen_width() - ball_radius) or ball_position.x <= float<-ball_radius:
                ball_speed.x *= -1.0
            if (
                ball_position.y >= float<-(rl.get_screen_height() - ball_radius)
                or ball_position.y <= float<-ball_radius
            ):
                ball_speed.y *= -0.95
        else:
            frames_counter += 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_circle_v(ball_position, float<-ball_radius, rl.MAROON)
        rl.draw_text("PRESS SPACE to PAUSE BALL MOVEMENT", 10, rl.get_screen_height() - 25, 20, rl.LIGHTGRAY)

        if use_gravity:
            rl.draw_text("GRAVITY: ON (Press G to disable)", 10, rl.get_screen_height() - 50, 20, rl.DARKGREEN)
        else:
            rl.draw_text("GRAVITY: OFF (Press G to enable)", 10, rl.get_screen_height() - 50, 20, rl.RED)

        if pause and (((frames_counter / 30) % 2) != 0):
            rl.draw_text("PAUSED", 350, 200, 30, rl.GRAY)

        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
