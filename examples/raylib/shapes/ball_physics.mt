import std.math as math
import std.raylib as rl
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_BALLS: int = 5000

struct Ball:
    position: rl.Vector2
    speed: rl.Vector2
    prev_position: rl.Vector2
    radius: float
    friction: float
    elasticity: float
    color: rl.Color
    grabbed: bool

var balls: array[Ball, MAX_BALLS] = zero[array[Ball, MAX_BALLS]]


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - ball physics")
    defer rl.close_window()

    balls[0] = Ball(
        position = rl.Vector2(x = float<-rl.get_screen_width() / 2.0, y = float<-rl.get_screen_height() / 2.0),
        speed = rl.Vector2(x = 200.0, y = 200.0),
        prev_position = zero[rl.Vector2],
        radius = 40.0,
        friction = 0.99,
        elasticity = 0.9,
        color = rl.BLUE,
        grabbed = false
    )

    var ball_count = 1
    var grabbed_ball_index = -1
    var press_offset: rl.Vector2 = zero[rl.Vector2]
    var gravity: float = 100.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let delta = rl.get_frame_time()
        let mouse_pos = rl.get_mouse_position()

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            var index = ball_count - 1
            while index >= 0:
                press_offset.x = mouse_pos.x - balls[index].position.x
                press_offset.y = mouse_pos.y - balls[index].position.y

                let distance = float<-math.sqrt(double<-((press_offset.x * press_offset.x) + (press_offset.y * press_offset.y)))
                if distance <= balls[index].radius:
                    balls[index].grabbed = true
                    grabbed_ball_index = index
                    break

                index -= 1

        if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
            if grabbed_ball_index != -1:
                balls[grabbed_ball_index].grabbed = false
                grabbed_ball_index = -1

        if (
            rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_RIGHT)
            or (rl.is_key_down(rl.KeyboardKey.KEY_LEFT_CONTROL) and rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_RIGHT))
        ):
            if ball_count < MAX_BALLS:
                balls[ball_count] = Ball(
                    position = mouse_pos,
                    speed = rl.Vector2(
                        x = float<-rl.get_random_value(-300, 300),
                        y = float<-rl.get_random_value(-300, 300)
                    ),
                    prev_position = zero[rl.Vector2],
                    radius = 20.0 + float<-rl.get_random_value(0, 30),
                    friction = 0.99,
                    elasticity = 0.9,
                    color = rl.Color(
                        r = ubyte<-rl.get_random_value(0, 255),
                        g = ubyte<-rl.get_random_value(0, 255),
                        b = ubyte<-rl.get_random_value(0, 255),
                        a = ubyte<-255
                    ),
                    grabbed = false
                )
                ball_count += 1

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_MIDDLE):
            var index = 0
            while index < ball_count:
                if not balls[index].grabbed:
                    balls[index].speed = rl.Vector2(
                        x = float<-rl.get_random_value(-2000, 2000),
                        y = float<-rl.get_random_value(-2000, 2000)
                    )
                index += 1

        gravity += rl.get_mouse_wheel_move() * 5.0

        var index = 0
        while index < ball_count:
            if not balls[index].grabbed:
                balls[index].position.x += balls[index].speed.x * delta
                balls[index].position.y += balls[index].speed.y * delta

                if balls[index].position.x + balls[index].radius >= float<-SCREEN_WIDTH:
                    balls[index].position.x = float<-SCREEN_WIDTH - balls[index].radius
                    balls[index].speed.x = -balls[index].speed.x * balls[index].elasticity
                else if balls[index].position.x - balls[index].radius <= 0.0:
                    balls[index].position.x = balls[index].radius
                    balls[index].speed.x = -balls[index].speed.x * balls[index].elasticity

                if balls[index].position.y + balls[index].radius >= float<-SCREEN_HEIGHT:
                    balls[index].position.y = float<-SCREEN_HEIGHT - balls[index].radius
                    balls[index].speed.y = -balls[index].speed.y * balls[index].elasticity
                else if balls[index].position.y - balls[index].radius <= 0.0:
                    balls[index].position.y = balls[index].radius
                    balls[index].speed.y = -balls[index].speed.y * balls[index].elasticity

                balls[index].speed.x *= balls[index].friction
                balls[index].speed.y = (balls[index].speed.y * balls[index].friction) + gravity
            else:
                balls[index].position.x = mouse_pos.x - press_offset.x
                balls[index].position.y = mouse_pos.y - press_offset.y
                balls[index].speed.x = (balls[index].position.x - balls[index].prev_position.x) / delta
                balls[index].speed.y = (balls[index].position.y - balls[index].prev_position.y) / delta
                balls[index].prev_position = balls[index].position

            index += 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        index = 0
        while index < ball_count:
            rl.draw_circle_v(balls[index].position, balls[index].radius, balls[index].color)
            rl.draw_circle_lines_v(balls[index].position, balls[index].radius, rl.BLACK)
            index += 1

        rl.draw_text("grab a ball by pressing with the mouse and throw it by releasing", 10, 10, 10, rl.DARKGRAY)
        rl.draw_text(
            "right click to create new balls (keep left control pressed to create a lot)",
            10,
            30,
            10,
            rl.DARKGRAY
        )
        rl.draw_text("use mouse wheel to change gravity", 10, 50, 10, rl.DARKGRAY)
        rl.draw_text("middle click to shake", 10, 70, 10, rl.DARKGRAY)
        rl.draw_text(
            text.cstr_as_str(rl.text_format("BALL COUNT: %d", ball_count)),
            10,
            rl.get_screen_height() - 70,
            20,
            rl.BLACK
        )
        rl.draw_text(
            text.cstr_as_str(rl.text_format("GRAVITY: %.2f", gravity)),
            10,
            rl.get_screen_height() - 40,
            20,
            rl.BLACK
        )

        rl.end_drawing()

    return 0
