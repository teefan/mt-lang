import std.math as math
import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const SIMULATION_STEPS: int = 30
const WORLD_GRAVITY: float = 9.81
const DEG_TO_RAD: float = rl.PI / 180.0
const RAD_TO_DEG: float = 180.0 / rl.PI


function calculate_pendulum_end_point(length: float, theta: float) -> rl.Vector2:
    return rl.Vector2(
        x = float<-(10.0 * length * float<-math.sin(double<-theta)),
        y = float<-(10.0 * length * float<-math.cos(double<-theta))
    )


function calculate_double_pendulum_end_point(
    length1: float,
    theta1: float,
    length2: float,
    theta2: float
) -> rl.Vector2:
    let endpoint1 = calculate_pendulum_end_point(length1, theta1)
    let endpoint2 = calculate_pendulum_end_point(length2, theta2)
    return rl.Vector2(x = float<-(endpoint1.x + endpoint2.x), y = float<-(endpoint1.y + endpoint2.y))


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_WINDOW_HIGHDPI)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - double pendulum")
    defer rl.close_window()

    let length1: float = 15.0
    let mass1: float = 0.2
    var theta1: float = DEG_TO_RAD * 170.0
    var velocity1: float = 0.0
    let length2: float = 15.0
    let mass2: float = 0.1
    var theta2: float = 0.0
    var velocity2: float = 0.0
    let length_scaler: float = 0.1
    let total_mass = mass1 + mass2

    var previous_position = calculate_double_pendulum_end_point(length1, theta1, length2, theta2)
    previous_position.x += float<-SCREEN_WIDTH / 2.0
    previous_position.y += float<-SCREEN_HEIGHT / 2.0 - 100.0

    let scaled_length1 = length1 * length_scaler
    let scaled_length2 = length2 * length_scaler
    let line_thickness: float = 20.0
    let trail_thickness: float = 2.0
    let trail_fade_alpha: float = 0.01

    let target = rl.load_render_texture(SCREEN_WIDTH, SCREEN_HEIGHT)
    defer rl.unload_render_texture(target)
    rl.set_texture_filter(target.texture, int<-rl.TextureFilter.TEXTURE_FILTER_BILINEAR)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let dt = rl.get_frame_time()
        let step = dt / float<-SIMULATION_STEPS
        let step2 = step * step

        var index = 0
        while index < SIMULATION_STEPS:
            let delta = theta1 - theta2
            let sin_delta = float<-math.sin(double<-delta)
            let cos_delta = float<-math.cos(double<-delta)
            let cos_double_delta = float<-math.cos(double<-(2.0 * delta))
            let velocity1_squared = velocity1 * velocity1
            let velocity2_squared = velocity2 * velocity2

            let acceleration1 = (
                -WORLD_GRAVITY * (2.0 * mass1 + mass2) * float<-math.sin(double<-theta1)
                - mass2 * WORLD_GRAVITY * float<-math.sin(double<-(theta1 - (2.0 * theta2)))
                - 2.0 * sin_delta * mass2 * (velocity2_squared * scaled_length2 + velocity1_squared * scaled_length1 * cos_delta)
            ) / (scaled_length1 * (2.0 * mass1 + mass2 - mass2 * cos_double_delta))

            let acceleration2 = (
                2.0 * sin_delta * (
                    velocity1_squared * scaled_length1 * total_mass
                    + WORLD_GRAVITY * total_mass * float<-math.cos(double<-theta1)
                    + velocity2_squared * scaled_length2 * mass2 * cos_delta
                )
            ) / (scaled_length2 * (2.0 * mass1 + mass2 - mass2 * cos_double_delta))

            theta1 += velocity1 * step + 0.5 * acceleration1 * step2
            theta2 += velocity2 * step + 0.5 * acceleration2 * step2
            velocity1 += acceleration1 * step
            velocity2 += acceleration2 * step
            index += 1

        var current_position = calculate_double_pendulum_end_point(length1, theta1, length2, theta2)
        current_position.x += float<-SCREEN_WIDTH / 2.0
        current_position.y += float<-SCREEN_HEIGHT / 2.0 - 100.0

        rl.begin_texture_mode(target)
        rl.draw_rectangle(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, rl.fade(rl.BLACK, trail_fade_alpha))
        rl.draw_circle_v(previous_position, trail_thickness, rl.RED)
        rl.draw_line_ex(previous_position, current_position, trail_thickness * 2.0, rl.RED)
        rl.end_texture_mode()

        previous_position = current_position

        rl.begin_drawing()
        rl.clear_background(rl.BLACK)
        rl.draw_texture_rec(
            target.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = float<-target.texture.width, height = -float<-target.texture.height),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE
        )

        rl.draw_rectangle_pro(
            rl.Rectangle(
                x = float<-SCREEN_WIDTH / 2.0,
                y = float<-SCREEN_HEIGHT / 2.0 - 100.0,
                width = 10.0 * length1,
                height = line_thickness
            ),
            rl.Vector2(x = 0.0, y = line_thickness * 0.5),
            90.0 - RAD_TO_DEG * theta1,
            rl.RAYWHITE
        )

        let endpoint1 = calculate_pendulum_end_point(length1, theta1)
        rl.draw_rectangle_pro(
            rl.Rectangle(
                x = float<-(float<-SCREEN_WIDTH / 2.0 + endpoint1.x),
                y = float<-(float<-SCREEN_HEIGHT / 2.0 - 100.0 + endpoint1.y),
                width = 10.0 * length2,
                height = line_thickness
            ),
            rl.Vector2(x = 0.0, y = line_thickness * 0.5),
            90.0 - RAD_TO_DEG * theta2,
            rl.RAYWHITE
        )

        rl.end_drawing()

    return 0
