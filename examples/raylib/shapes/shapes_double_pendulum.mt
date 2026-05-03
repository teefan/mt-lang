module examples.raylib.shapes.shapes_double_pendulum

import std.c.libm as math
import std.c.raylib as rl
import std.math as mt_math

const simulation_steps: i32 = 30
const gravity: f32 = 9.81
const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - double pendulum"

def calculate_pendulum_end_point(length: f32, theta: f32) -> rl.Vector2:
    return rl.Vector2(
        x = 10.0 * length * math.sinf(theta),
        y = 10.0 * length * math.cosf(theta),
    )

def calculate_double_pendulum_end_point(length1: f32, theta1: f32, length2: f32, theta2: f32) -> rl.Vector2:
    let endpoint1 = calculate_pendulum_end_point(length1, theta1)
    let endpoint2 = calculate_pendulum_end_point(length2, theta2)
    return rl.Vector2(x = endpoint1.x + endpoint2.x, y = endpoint1.y + endpoint2.y)

def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_WINDOW_HIGHDPI)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var length1: f32 = 15.0
    var mass1: f32 = 0.2
    var theta1: f32 = mt_math.deg2rad * 170.0
    var omega1: f32 = 0.0
    var length2: f32 = 15.0
    var mass2: f32 = 0.1
    var theta2: f32 = 0.0
    var omega2: f32 = 0.0
    let total_mass = mass1 + mass2

    var previous_position = calculate_double_pendulum_end_point(length1, theta1, length2, theta2)
    previous_position.x += f32<-screen_width / 2.0
    previous_position.y += f32<-screen_height / 2.0 - 100.0

    let line_thickness: f32 = 20.0
    let trail_thickness: f32 = 2.0
    let fade_alpha: f32 = 0.01

    let target = rl.LoadRenderTexture(screen_width, screen_height)
    defer rl.UnloadRenderTexture(target)
    rl.SetTextureFilter(target.texture, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let delta_time = rl.GetFrameTime()
        let step = delta_time / f32<-simulation_steps
        let step2 = step * step

        for _ in range(0, simulation_steps):
            let delta = theta1 - theta2
            let sin_delta = math.sinf(delta)
            let cos_delta = math.cosf(delta)
            let cos_2_delta = math.cosf(2.0 * delta)
            let omega1_sq = omega1 * omega1
            let omega2_sq = omega2 * omega2

            let alpha1 = (
                -gravity * (2.0 * mass1 + mass2) * math.sinf(theta1)
                - mass2 * gravity * math.sinf(theta1 - 2.0 * theta2)
                - 2.0 * sin_delta * mass2 * (omega2_sq * 10.0 * length2 + omega1_sq * 10.0 * length1 * cos_delta)
            ) / (10.0 * length1 * (2.0 * mass1 + mass2 - mass2 * cos_2_delta))

            let alpha2 = (
                2.0 * sin_delta * (
                    omega1_sq * 10.0 * length1 * total_mass
                    + gravity * total_mass * math.cosf(theta1)
                    + omega2_sq * 10.0 * length2 * mass2 * cos_delta
                )
            ) / (10.0 * length2 * (2.0 * mass1 + mass2 - mass2 * cos_2_delta))

            theta1 += omega1 * step + 0.5 * alpha1 * step2
            theta2 += omega2 * step + 0.5 * alpha2 * step2
            omega1 += alpha1 * step
            omega2 += alpha2 * step

        var current_position = calculate_double_pendulum_end_point(length1, theta1, length2, theta2)
        current_position.x += f32<-screen_width / 2.0
        current_position.y += f32<-screen_height / 2.0 - 100.0

        rl.BeginTextureMode(target)
        rl.DrawRectangle(0, 0, screen_width, screen_height, rl.Fade(rl.BLACK, fade_alpha))
        rl.DrawCircleV(previous_position, trail_thickness, rl.RED)
        rl.DrawLineEx(previous_position, current_position, trail_thickness * 2.0, rl.RED)
        rl.EndTextureMode()

        previous_position = current_position
        let endpoint1 = calculate_pendulum_end_point(length1, theta1)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)
        rl.DrawTextureRec(
            target.texture,
            rl.Rectangle(
                x = 0.0,
                y = 0.0,
                width = target.texture.width,
                height = -target.texture.height,
            ),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE,
        )

        rl.DrawRectanglePro(
            rl.Rectangle(
                x = f32<-screen_width / 2.0,
                y = f32<-screen_height / 2.0 - 100.0,
                width = 10.0 * length1,
                height = line_thickness,
            ),
            rl.Vector2(x = 0.0, y = line_thickness * 0.5),
            90.0 - mt_math.rad2deg * theta1,
            rl.RAYWHITE,
        )
        rl.DrawRectanglePro(
            rl.Rectangle(
                x = f32<-screen_width / 2.0 + endpoint1.x,
                y = f32<-screen_height / 2.0 - 100.0 + endpoint1.y,
                width = 10.0 * length2,
                height = line_thickness,
            ),
            rl.Vector2(x = 0.0, y = line_thickness * 0.5),
            90.0 - mt_math.rad2deg * theta2,
            rl.RAYWHITE,
        )

    return 0