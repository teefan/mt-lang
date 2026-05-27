import std.raylib as rl
import std.raymath as math
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const STAR_COUNT: int = 420


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - starfield effect")
    defer rl.close_window()

    let bg_color = rl.color_lerp(rl.DARKBLUE, rl.BLACK, 0.69)
    var speed: float = 10.0 / 9.0
    var draw_lines = true
    var stars: array[rl.Vector3, STAR_COUNT] = zero[array[rl.Vector3, STAR_COUNT]]
    var stars_screen_pos: array[rl.Vector2, STAR_COUNT] = zero[array[rl.Vector2, STAR_COUNT]]

    var index = 0
    while index < STAR_COUNT:
        stars[index].x = float<-rl.get_random_value(-SCREEN_WIDTH / 2, SCREEN_WIDTH / 2)
        stars[index].y = float<-rl.get_random_value(-SCREEN_HEIGHT / 2, SCREEN_HEIGHT / 2)
        stars[index].z = 1.0
        index += 1

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse_move = rl.get_mouse_wheel_move()
        if int<-mouse_move != 0:
            speed += 2.0 * mouse_move / 9.0

        if speed < 0.0:
            speed = 0.1
        else if speed > 2.0:
            speed = 2.0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            draw_lines = not draw_lines

        let dt = rl.get_frame_time()

        index = 0
        while index < STAR_COUNT:
            stars[index].z -= dt * speed
            stars_screen_pos[index] = rl.Vector2(
                x = float<-SCREEN_WIDTH * 0.5 + stars[index].x / stars[index].z,
                y = float<-SCREEN_HEIGHT * 0.5 + stars[index].y / stars[index].z,
            )

            if stars[index].z < 0.0 or stars_screen_pos[index].x < 0.0 or stars_screen_pos[index].y < 0.0 or stars_screen_pos[index].x > float<-SCREEN_WIDTH or stars_screen_pos[index].y > float<-SCREEN_HEIGHT:
                stars[index].x = float<-rl.get_random_value(-SCREEN_WIDTH / 2, SCREEN_WIDTH / 2)
                stars[index].y = float<-rl.get_random_value(-SCREEN_HEIGHT / 2, SCREEN_HEIGHT / 2)
                stars[index].z = 1.0

            index += 1

        rl.begin_drawing()
        rl.clear_background(bg_color)

        index = 0
        while index < STAR_COUNT:
            if draw_lines:
                let t = math.clamp(stars[index].z + (1.0 / 32.0), 0.0, 1.0)
                if (t - stars[index].z) > 0.001:
                    let start_pos = rl.Vector2(
                        x = float<-SCREEN_WIDTH * 0.5 + stars[index].x / t,
                        y = float<-SCREEN_HEIGHT * 0.5 + stars[index].y / t,
                    )
                    rl.draw_line_v(start_pos, stars_screen_pos[index], rl.RAYWHITE)
            else:
                let radius = math.lerp(stars[index].z, 1.0, 5.0)
                rl.draw_circle_v(stars_screen_pos[index], radius, rl.RAYWHITE)
            index += 1

        rl.draw_text(text.cstr_as_str(rl.text_format("[MOUSE WHEEL] Current Speed: %.0f", 9.0 * speed / 2.0)), 10, 40, 20, rl.RAYWHITE)
        let draw_mode = if draw_lines: "Lines" else: "Circles"
        rl.draw_text(text.cstr_as_str(rl.text_format("[SPACE] Current draw mode: %s", draw_mode)), 10, 70, 20, rl.RAYWHITE)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
