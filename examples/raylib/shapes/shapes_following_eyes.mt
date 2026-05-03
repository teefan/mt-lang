module examples.raylib.shapes.shapes_following_eyes

import std.c.libm as math
import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - following eyes"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let sclera_left_position = rl.Vector2(x = rl.GetScreenWidth() / 2.0 - 100.0, y = rl.GetScreenHeight() / 2.0)
    let sclera_right_position = rl.Vector2(x = rl.GetScreenWidth() / 2.0 + 100.0, y = rl.GetScreenHeight() / 2.0)
    let sclera_radius: f32 = 80.0

    var iris_left_position = sclera_left_position
    var iris_right_position = sclera_right_position
    let iris_radius: f32 = 24.0

    var angle: f32 = 0.0
    var dx: f32 = 0.0
    var dy: f32 = 0.0
    var dxx: f32 = 0.0
    var dyy: f32 = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        iris_left_position = rl.GetMousePosition()
        iris_right_position = rl.GetMousePosition()

        if not rl.CheckCollisionPointCircle(iris_left_position, sclera_left_position, sclera_radius - iris_radius):
            dx = iris_left_position.x - sclera_left_position.x
            dy = iris_left_position.y - sclera_left_position.y
            angle = math.atan2f(dy, dx)
            dxx = (sclera_radius - iris_radius) * math.cosf(angle)
            dyy = (sclera_radius - iris_radius) * math.sinf(angle)
            iris_left_position.x = sclera_left_position.x + dxx
            iris_left_position.y = sclera_left_position.y + dyy

        if not rl.CheckCollisionPointCircle(iris_right_position, sclera_right_position, sclera_radius - iris_radius):
            dx = iris_right_position.x - sclera_right_position.x
            dy = iris_right_position.y - sclera_right_position.y
            angle = math.atan2f(dy, dx)
            dxx = (sclera_radius - iris_radius) * math.cosf(angle)
            dyy = (sclera_radius - iris_radius) * math.sinf(angle)
            iris_right_position.x = sclera_right_position.x + dxx
            iris_right_position.y = sclera_right_position.y + dyy

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawCircleV(sclera_left_position, sclera_radius, rl.LIGHTGRAY)
        rl.DrawCircleV(iris_left_position, iris_radius, rl.BROWN)
        rl.DrawCircleV(iris_left_position, 10.0, rl.BLACK)

        rl.DrawCircleV(sclera_right_position, sclera_radius, rl.LIGHTGRAY)
        rl.DrawCircleV(iris_right_position, iris_radius, rl.DARKGREEN)
        rl.DrawCircleV(iris_right_position, 10.0, rl.BLACK)

        rl.DrawFPS(10, 10)

    return 0