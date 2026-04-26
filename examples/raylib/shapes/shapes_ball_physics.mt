module examples.raylib.shapes.shapes_ball_physics

import std.c.libm as math
import std.c.raylib as rl
import std.mem.heap as heap

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
const window_title: cstr = c"raylib [shapes] example - ball physics"
const help_text_1: cstr = c"grab a ball by pressing with the mouse and throw it by releasing"
const help_text_2: cstr = c"right click to create new balls (keep left control pressed to create a lot)"
const help_text_3: cstr = c"use mouse wheel to change gravity"
const help_text_4: cstr = c"middle click to shake"
const ball_count_format: cstr = c"BALL COUNT: %d"
const gravity_format: cstr = c"GRAVITY: %.2f"

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
    return math.sqrtf(dx * dx + dy * dy)

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let balls = heap.alloc_zeroed[Ball](cast[usize](max_balls))
    defer heap.release(balls)

    var ball_count = 1
    var balls_view = span[Ball](data = balls, len = cast[usize](ball_count))
    balls_view[0] = ball_at(
        rl.Vector2(x = rl.GetScreenWidth() / 2.0, y = rl.GetScreenHeight() / 2.0),
        rl.Vector2(x = 200.0, y = 200.0),
        40.0,
        rl.BLUE,
    )

    var grabbed_index = -1
    var press_offset = rl.Vector2(x = 0.0, y = 0.0)
    var gravity: f32 = 100.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let delta = rl.GetFrameTime()
        let mouse_pos = rl.GetMousePosition()
        balls_view = span[Ball](data = balls, len = cast[usize](ball_count))

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            var index = ball_count
            while index > 0:
                index -= 1
                press_offset.x = mouse_pos.x - balls_view[index].position.x
                press_offset.y = mouse_pos.y - balls_view[index].position.y

                if distance(mouse_pos, balls_view[index].position) <= balls_view[index].radius:
                    balls_view[index].grabbed = true
                    grabbed_index = index
                    break

        if rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT):
            if grabbed_index >= 0:
                balls_view[grabbed_index].grabbed = false
                grabbed_index = -1

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_RIGHT) or (rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT_CONTROL) and rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_RIGHT)):
            if ball_count < max_balls:
                let new_index = ball_count
                ball_count += 1
                balls_view = span[Ball](data = balls, len = cast[usize](ball_count))
                balls_view[new_index] = ball_at(
                    mouse_pos,
                    rl.Vector2(
                        x = cast[f32](rl.GetRandomValue(-300, 300)),
                        y = cast[f32](rl.GetRandomValue(-300, 300)),
                    ),
                    20.0 + cast[f32](rl.GetRandomValue(0, 30)),
                    rl.Color(
                        r = rl.GetRandomValue(0, 255),
                        g = rl.GetRandomValue(0, 255),
                        b = rl.GetRandomValue(0, 255),
                        a = 255,
                    ),
                )

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_MIDDLE):
            for index in range(0, ball_count):
                if not balls_view[index].grabbed:
                    balls_view[index].speed = rl.Vector2(
                        x = cast[f32](rl.GetRandomValue(-2000, 2000)),
                        y = cast[f32](rl.GetRandomValue(-2000, 2000)),
                    )

        gravity += rl.GetMouseWheelMove() * 5.0

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

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        for index in range(0, ball_count):
            rl.DrawCircleV(balls_view[index].position, balls_view[index].radius, balls_view[index].color)
            rl.DrawCircleLinesV(balls_view[index].position, balls_view[index].radius, rl.BLACK)

        rl.DrawText(help_text_1, 10, 10, 10, rl.DARKGRAY)
        rl.DrawText(help_text_2, 10, 30, 10, rl.DARKGRAY)
        rl.DrawText(help_text_3, 10, 50, 10, rl.DARKGRAY)
        rl.DrawText(help_text_4, 10, 70, 10, rl.DARKGRAY)
        rl.DrawText(rl.TextFormat(ball_count_format, ball_count), 10, rl.GetScreenHeight() - 70, 20, rl.BLACK)
        rl.DrawText(rl.TextFormat(gravity_format, gravity), 10, rl.GetScreenHeight() - 40, 20, rl.BLACK)

    return 0
