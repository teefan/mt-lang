module examples.idiomatic.raylib.starfield_effect

import std.raylib as rl
import std.raylib.math as math

const screen_width: i32 = 800
const screen_height: i32 = 450
const star_count: i32 = 420


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Starfield Effect")
    defer rl.close_window()

    let background = rl.color_lerp(rl.DARKBLUE, rl.BLACK, 0.69)
    var speed: f32 = 10.0 / 9.0
    var draw_lines = true
    var stars = zero[array[rl.Vector3, 420]]()
    var screen_positions = zero[array[rl.Vector2, 420]]()

    for index in range(0, star_count):
        stars[index].x = f32<-rl.get_random_value(-screen_width / 2, screen_width / 2)
        stars[index].y = f32<-rl.get_random_value(-screen_height / 2, screen_height / 2)
        stars[index].z = 1.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse_wheel = rl.get_mouse_wheel_move()
        if i32<-mouse_wheel != 0:
            speed += 2.0 * mouse_wheel / 9.0
        speed = math.clamp(speed, 0.1, 2.0)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            draw_lines = not draw_lines

        let dt = rl.get_frame_time()
        for index in range(0, star_count):
            stars[index].z -= dt * speed
            screen_positions[index] = rl.Vector2(
                x = f32<-screen_width * 0.5 + stars[index].x / stars[index].z,
                y = f32<-screen_height * 0.5 + stars[index].y / stars[index].z,
            )

            if stars[index].z < 0.0 or screen_positions[index].x < 0.0 or screen_positions[index].y < 0.0 or screen_positions[index].x > f32<-screen_width or screen_positions[index].y > f32<-screen_height:
                stars[index].x = f32<-rl.get_random_value(-screen_width / 2, screen_width / 2)
                stars[index].y = f32<-rl.get_random_value(-screen_height / 2, screen_height / 2)
                stars[index].z = 1.0

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(background)

        for index in range(0, star_count):
            if draw_lines:
                let t = math.clamp(stars[index].z + 1.0 / 32.0, 0.0, 1.0)
                if t - stars[index].z > 0.001:
                    let start_position = rl.Vector2(
                        x = f32<-screen_width * 0.5 + stars[index].x / t,
                        y = f32<-screen_height * 0.5 + stars[index].y / t,
                    )
                    rl.draw_line_v(start_position, screen_positions[index], rl.RAYWHITE)
            else:
                rl.draw_circle_v(screen_positions[index], math.lerp(stars[index].z, 1.0, 5.0), rl.RAYWHITE)

        rl.draw_text(rl.text_format_f32("[MOUSE WHEEL] Current Speed: %.0f", 9.0 * speed / 2.0), 10, 40, 20, rl.RAYWHITE)
        rl.draw_text(rl.text_format_cstr("[SPACE] Current draw mode: %s", if draw_lines: "Lines" else: "Circles"), 10, 70, 20, rl.RAYWHITE)
        rl.draw_fps(10, 10)

    return 0
