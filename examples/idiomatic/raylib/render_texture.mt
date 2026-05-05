module examples.idiomatic.raylib.render_texture

import std.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const render_texture_width: int = 300
const render_texture_height: int = 300
const ball_radius: float = 20.0


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea Render Texture")
    defer rl.close_window()

    let target = rl.load_render_texture(render_texture_width, render_texture_height)
    defer rl.unload_render_texture(target)

    var ball_position = rl.Vector2(
        x = 0.5 * render_texture_width,
        y = 0.5 * render_texture_height,
    )
    var ball_speed = rl.Vector2(x = 5.0, y = 4.0)
    var rotation: float = 0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        ball_position.x += ball_speed.x
        ball_position.y += ball_speed.y

        if ball_position.x >= render_texture_width - ball_radius or ball_position.x <= ball_radius:
            ball_speed.x *= -1.0
        if ball_position.y >= render_texture_height - ball_radius or ball_position.y <= ball_radius:
            ball_speed.y *= -1.0

        rotation += 0.5

        rl.begin_texture_mode(target)
        rl.clear_background(rl.SKYBLUE)
        rl.draw_rectangle(0, 0, 20, 20, rl.RED)
        rl.draw_circle_v(ball_position, ball_radius, rl.MAROON)
        rl.end_texture_mode()

        rl.begin_drawing()
        defer rl.end_drawing()

        let source = rl.Rectangle(
            x = 0,
            y = 0,
            width = target.texture.width,
            height = -target.texture.height,
        )
        let dest = rl.Rectangle(
            x = 0.5 * screen_width,
            y = 0.5 * screen_height,
            width = target.texture.width,
            height = target.texture.height,
        )
        let origin = rl.Vector2(
            x = 0.5 * target.texture.width,
            y = 0.5 * target.texture.height,
        )

        rl.clear_background(rl.RAYWHITE)
        rl.draw_texture_pro(target.texture, source, dest, origin, rotation, rl.WHITE)
        rl.draw_text("DRAWING BOUNCING BALL INSIDE RENDER TEXTURE!", 10, screen_height - 40, 20, rl.BLACK)
        rl.draw_fps(10, 10)

    return 0
