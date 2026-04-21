module demo.bouncing_ball

import std.c.raylib as rl

const screen_width: i32 = 1280
const screen_height: i32 = 720
const window_title: cstr = c"Milk Tea Demo"

struct Ball:
    position: rl.Vector2
    velocity: rl.Vector2
    radius: f32
    color: rl.Color

impl Ball:
    def update(mut self, dt: f32):
        self.position.x += self.velocity.x * dt
        self.position.y += self.velocity.y * dt

        if self.position.x < self.radius or self.position.x > cast[f32](screen_width) - self.radius:
            self.velocity.x = -self.velocity.x

        if self.position.y < self.radius or self.position.y > cast[f32](screen_height) - self.radius:
            self.velocity.y = -self.velocity.y

    def draw(self):
        rl.DrawCircleV(self.position, self.radius, self.color)

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.SetTargetFPS(60)

    var ball = Ball(
        position = rl.Vector2(x = 300.0, y = 240.0),
        velocity = rl.Vector2(x = 240.0, y = 180.0),
        radius = 20.0,
        color = rl.GOLD,
    )

    while not rl.WindowShouldClose():
        let dt = rl.GetFrameTime()
        ball.update(dt)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)
        ball.draw()

    return 0
