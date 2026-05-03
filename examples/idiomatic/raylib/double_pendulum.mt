module examples.idiomatic.raylib.double_pendulum

import std.raylib as rl
import std.raylib.math as math

const simulation_steps: i32 = 30
const gravity: f32 = 9.81
const screen_width: i32 = 800
const screen_height: i32 = 450

def calculate_pendulum_end_point(length: f32, theta: f32) -> rl.Vector2:
    return rl.Vector2(
        x = 10.0 * length * math.sin(theta),
        y = 10.0 * length * math.cos(theta),
    )

def calculate_double_pendulum_end_point(length1: f32, theta1: f32, length2: f32, theta2: f32) -> rl.Vector2:
    let endpoint1 = calculate_pendulum_end_point(length1, theta1)
    let endpoint2 = calculate_pendulum_end_point(length2, theta2)
    return rl.Vector2(x = endpoint1.x + endpoint2.x, y = endpoint1.y + endpoint2.y)

def main() -> i32:
    rl.set_config_flags(rl.ConfigFlags.FLAG_WINDOW_HIGHDPI)
    rl.init_window(screen_width, screen_height, "Milk Tea Double Pendulum")
    defer rl.close_window()

    let length1: f32 = 15.0
    let mass1: f32 = 0.2
    var theta1: f32 = math.deg2rad * 170.0
    var omega1: f32 = 0.0
    let length2: f32 = 15.0
    let mass2: f32 = 0.1
    var theta2: f32 = 0.0
    var omega2: f32 = 0.0
    let total_mass = mass1 + mass2

    var previous_position = calculate_double_pendulum_end_point(length1, theta1, length2, theta2)
    previous_position.x += f32<-screen_width / 2.0
    previous_position.y += f32<-screen_height / 2.0 - 100.0

    let line_thickness: f32 = 20.0
    let trail_thickness: f32 = 2.0
    let fade_alpha: f32 = 0.01

    let target = rl.load_render_texture(screen_width, screen_height)
    defer rl.unload_render_texture(target)
    rl.set_texture_filter(target.texture, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let delta_time = rl.get_frame_time()
        let step = delta_time / f32<-simulation_steps
        let step2 = step * step

        for _ in range(0, simulation_steps):
            let delta = theta1 - theta2
            let sin_delta = math.sin(delta)
            let cos_delta = math.cos(delta)
            let cos_2_delta = math.cos(2.0 * delta)
            let omega1_sq = omega1 * omega1
            let omega2_sq = omega2 * omega2

            let alpha1 = (
                -gravity * (2.0 * mass1 + mass2) * math.sin(theta1)
                - mass2 * gravity * math.sin(theta1 - 2.0 * theta2)
                - 2.0 * sin_delta * mass2 * (omega2_sq * 10.0 * length2 + omega1_sq * 10.0 * length1 * cos_delta)
            ) / (10.0 * length1 * (2.0 * mass1 + mass2 - mass2 * cos_2_delta))

            let alpha2 = (
                2.0 * sin_delta * (
                    omega1_sq * 10.0 * length1 * total_mass
                    + gravity * total_mass * math.cos(theta1)
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

        rl.begin_texture_mode(target)
        rl.draw_rectangle(0, 0, screen_width, screen_height, rl.fade(rl.BLACK, fade_alpha))
        rl.draw_circle_v(previous_position, trail_thickness, rl.RED)
        rl.draw_line_ex(previous_position, current_position, trail_thickness * 2.0, rl.RED)
        rl.end_texture_mode()

        previous_position = current_position
        let endpoint1 = calculate_pendulum_end_point(length1, theta1)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.BLACK)
        rl.draw_texture_rec(
            target.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = target.texture.width, height = -target.texture.height),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE,
        )

        rl.draw_rectangle_pro(
            rl.Rectangle(
                x = f32<-screen_width / 2.0,
                y = f32<-screen_height / 2.0 - 100.0,
                width = 10.0 * length1,
                height = line_thickness,
            ),
            rl.Vector2(x = 0.0, y = line_thickness * 0.5),
            90.0 - math.rad2deg * theta1,
            rl.RAYWHITE,
        )
        rl.draw_rectangle_pro(
            rl.Rectangle(
                x = f32<-screen_width / 2.0 + endpoint1.x,
                y = f32<-screen_height / 2.0 - 100.0 + endpoint1.y,
                width = 10.0 * length2,
                height = line_thickness,
            ),
            rl.Vector2(x = 0.0, y = line_thickness * 0.5),
            90.0 - math.rad2deg * theta2,
            rl.RAYWHITE,
        )

    return 0