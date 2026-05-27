import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const RENDER_TEXTURE_WIDTH: int = 300
const RENDER_TEXTURE_HEIGHT: int = 300
const BALL_RADIUS: float = 20.0


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - render texture")
    defer rl.close_window()

    let target = rl.load_render_texture(RENDER_TEXTURE_WIDTH, RENDER_TEXTURE_HEIGHT)
    defer rl.unload_render_texture(target)

    var ball_position = rl.Vector2(
        x = (float<-RENDER_TEXTURE_WIDTH) / 2.0,
        y = (float<-RENDER_TEXTURE_HEIGHT) / 2.0,
    )
    var ball_speed = rl.Vector2(x = 5.0, y = 4.0)
    var rotation: float = 0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        ball_position.x += ball_speed.x
        ball_position.y += ball_speed.y

        if ball_position.x >= (float<-RENDER_TEXTURE_WIDTH) - BALL_RADIUS or ball_position.x <= BALL_RADIUS:
            ball_speed.x *= -1.0
        if ball_position.y >= (float<-RENDER_TEXTURE_HEIGHT) - BALL_RADIUS or ball_position.y <= BALL_RADIUS:
            ball_speed.y *= -1.0

        rotation += 0.5

        rl.begin_texture_mode(target)
        rl.clear_background(rl.SKYBLUE)
        rl.draw_rectangle(0, 0, 20, 20, rl.RED)
        rl.draw_circle_v(ball_position, BALL_RADIUS, rl.MAROON)
        rl.end_texture_mode()

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        let source = rl.Rectangle(
            x = 0.0,
            y = 0.0,
            width = float<-target.texture.width,
            height = -(float<-target.texture.height),
        )
        let destination = rl.Rectangle(
            x = (float<-SCREEN_WIDTH) / 2.0,
            y = (float<-SCREEN_HEIGHT) / 2.0,
            width = float<-target.texture.width,
            height = float<-target.texture.height,
        )
        let origin = rl.Vector2(
            x = (float<-target.texture.width) / 2.0,
            y = (float<-target.texture.height) / 2.0,
        )
        rl.draw_texture_pro(target.texture, source, destination, origin, rotation, rl.WHITE)

        rl.draw_text("DRAWING BOUNCING BALL INSIDE RENDER TEXTURE!", 10, SCREEN_HEIGHT - 40, 20, rl.BLACK)
        rl.draw_fps(10, 10)

        rl.end_drawing()

    return 0
