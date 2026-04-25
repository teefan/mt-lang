module examples.idiomatic.raylib.bouncing_ball

import std.raylib as rl

const screen_width: i32 = 1280
const screen_height: i32 = 720

struct Ball:
    position: rl.Vector2
    velocity: rl.Vector2
    radius: f32
    color: rl.Color

methods Ball:
    edit def update(dt: f32):
        this.position.x += this.velocity.x * dt
        this.position.y += this.velocity.y * dt

        if this.position.x < this.radius or this.position.x > screen_width - this.radius:
            this.velocity.x = -this.velocity.x

        if this.position.y < this.radius or this.position.y > screen_height - this.radius:
            this.velocity.y = -this.velocity.y

    def draw():
        rl.draw_circle_v(this.position, this.radius, this.color)

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Bouncing Ball")
    defer rl.close_window()

    rl.set_target_fps(60)

    var ball = Ball(
        position = rl.Vector2(x = 300.0, y = 240.0),
        velocity = rl.Vector2(x = 240.0, y = 180.0),
        radius = 20.0,
        color = rl.GOLD,
    )

    while not rl.window_should_close():
        let dt = rl.get_frame_time()
        ball.update(dt)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.BLACK)
        ball.draw()

    return 0
