module examples.idiomatic.raylib.ball_physics

import std.mem.heap as heap
import std.raylib as rl
import std.raylib.math as math
import std.span as sp

struct Ball:
    position: rl.Vector2
    speed: rl.Vector2
    prev_position: rl.Vector2
    radius: f32
    friction: f32
    elasticity: f32
    color: rl.Color
    grabbed: bool

const screen_width: i32 = 800
const screen_height: i32 = 450
const max_balls: i32 = 5000


def ball_at(position: rl.Vector2, speed: rl.Vector2, radius: f32, color: rl.Color) -> Ball:
    return Ball(
        position = position,
        speed = speed,
        prev_position = rl.Vector2(x = 0.0, y = 0.0),
        radius = radius,
        friction = 0.99,
        elasticity = 0.9,
        color = color,
        grabbed = false,
    )


def distance(left: rl.Vector2, right: rl.Vector2) -> f32:
    let dx = left.x - right.x
    let dy = left.y - right.y
    return math.sqrt(dx * dx + dy * dy)


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Ball Physics")
    defer rl.close_window()

    let balls = heap.must_alloc_zeroed[Ball](usize<-max_balls)
    defer heap.release(balls)

    var ball_count = 1
    var balls_view = sp.from_ptr[Ball](balls, usize<-ball_count)
    balls_view[0] = ball_at(
        rl.Vector2(x = rl.get_screen_width() / 2.0, y = rl.get_screen_height() / 2.0),
        rl.Vector2(x = 200.0, y = 200.0),
        40.0,
        rl.BLUE,
    )

    var grabbed_index = -1
    var press_offset = rl.Vector2(x = 0.0, y = 0.0)
    var gravity: f32 = 100.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let delta = rl.get_frame_time()
        let mouse_pos = rl.get_mouse_position()
        balls_view = sp.from_ptr[Ball](balls, usize<-ball_count)

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            var index = ball_count
            while index > 0:
                index -= 1
                press_offset.x = mouse_pos.x - balls_view[index].position.x
                press_offset.y = mouse_pos.y - balls_view[index].position.y

                if distance(mouse_pos, balls_view[index].position) <= balls_view[index].radius:
                    balls_view[index].grabbed = true
                    grabbed_index = index
                    break

        if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
            if grabbed_index >= 0:
                balls_view[grabbed_index].grabbed = false
                grabbed_index = -1

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_RIGHT) or (rl.is_key_down(rl.KeyboardKey.KEY_LEFT_CONTROL) and rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_RIGHT)):
            if ball_count < max_balls:
                let new_index = ball_count
                ball_count += 1
                balls_view = sp.from_ptr[Ball](balls, usize<-ball_count)
                balls_view[new_index] = ball_at(
                    mouse_pos,
                    rl.Vector2(
                        x = f32<-rl.get_random_value(-300, 300),
                        y = f32<-rl.get_random_value(-300, 300),
                    ),
                    20.0 + f32<-rl.get_random_value(0, 30),
                    rl.Color(
                        r = u8<-rl.get_random_value(0, 255),
                        g = u8<-rl.get_random_value(0, 255),
                        b = u8<-rl.get_random_value(0, 255),
                        a = 255,
                    ),
                )

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_MIDDLE):
            for index in range(0, ball_count):
                if not balls_view[index].grabbed:
                    balls_view[index].speed = rl.Vector2(
                        x = f32<-rl.get_random_value(-2000, 2000),
                        y = f32<-rl.get_random_value(-2000, 2000),
                    )

        gravity += rl.get_mouse_wheel_move() * 5.0

        for index in range(0, ball_count):
            if not balls_view[index].grabbed:
                balls_view[index].position.x += balls_view[index].speed.x * delta
                balls_view[index].position.y += balls_view[index].speed.y * delta

                if balls_view[index].position.x + balls_view[index].radius >= screen_width:
                    balls_view[index].position.x = screen_width - balls_view[index].radius
                    balls_view[index].speed.x = -balls_view[index].speed.x * balls_view[index].elasticity
                elif balls_view[index].position.x - balls_view[index].radius <= 0.0:
                    balls_view[index].position.x = balls_view[index].radius
                    balls_view[index].speed.x = -balls_view[index].speed.x * balls_view[index].elasticity

                if balls_view[index].position.y + balls_view[index].radius >= screen_height:
                    balls_view[index].position.y = screen_height - balls_view[index].radius
                    balls_view[index].speed.y = -balls_view[index].speed.y * balls_view[index].elasticity
                elif balls_view[index].position.y - balls_view[index].radius <= 0.0:
                    balls_view[index].position.y = balls_view[index].radius
                    balls_view[index].speed.y = -balls_view[index].speed.y * balls_view[index].elasticity

                balls_view[index].speed.x *= balls_view[index].friction
                balls_view[index].speed.y = balls_view[index].speed.y * balls_view[index].friction + gravity
            else:
                balls_view[index].position.x = mouse_pos.x - press_offset.x
                balls_view[index].position.y = mouse_pos.y - press_offset.y
                balls_view[index].speed.x = (balls_view[index].position.x - balls_view[index].prev_position.x) / delta
                balls_view[index].speed.y = (balls_view[index].position.y - balls_view[index].prev_position.y) / delta
                balls_view[index].prev_position = balls_view[index].position

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        for index in range(0, ball_count):
            rl.draw_circle_v(balls_view[index].position, balls_view[index].radius, balls_view[index].color)
            rl.draw_circle_lines_v(balls_view[index].position, balls_view[index].radius, rl.BLACK)

        rl.draw_text("grab a ball by pressing with the mouse and throw it by releasing", 10, 10, 10, rl.DARKGRAY)
        rl.draw_text("right click to create new balls (keep left control pressed to create a lot)", 10, 30, 10, rl.DARKGRAY)
        rl.draw_text("use mouse wheel to change gravity", 10, 50, 10, rl.DARKGRAY)
        rl.draw_text("middle click to shake", 10, 70, 10, rl.DARKGRAY)
        rl.draw_text(rl.text_format_i32("BALL COUNT: %d", ball_count), 10, rl.get_screen_height() - 70, 20, rl.BLACK)
        rl.draw_text(rl.text_format_f32("GRAVITY: %.2f", gravity), 10, rl.get_screen_height() - 40, 20, rl.BLACK)

    return 0
