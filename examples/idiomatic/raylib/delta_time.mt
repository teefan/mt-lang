module examples.idiomatic.raylib.delta_time

import std.raylib as rl

const screen_width: int = 800
const screen_height: int = 450


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea Delta Time")
    defer rl.close_window()

    var current_fps = 60
    var delta_circle = rl.Vector2(x = 0.0, y = 0.33333334 * screen_height)
    var frame_circle = rl.Vector2(x = 0.0, y = 0.6666667 * screen_height)
    let speed: float = 10.0
    let circle_radius: float = 32.0

    rl.set_target_fps(current_fps)

    while not rl.window_should_close():
        let mouse_wheel = rl.get_mouse_wheel_move()
        if mouse_wheel != 0.0:
            current_fps += int<-mouse_wheel
            if current_fps < 0:
                current_fps = 0
            rl.set_target_fps(current_fps)

        delta_circle.x += rl.get_frame_time() * 6.0 * speed
        frame_circle.x += 0.1 * speed

        if delta_circle.x > screen_width:
            delta_circle.x = 0.0
        if frame_circle.x > screen_width:
            frame_circle.x = 0.0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            delta_circle.x = 0.0
            frame_circle.x = 0.0

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_circle_v(delta_circle, circle_radius, rl.RED)
        rl.draw_circle_v(frame_circle, circle_radius, rl.BLUE)

        if current_fps <= 0:
            rl.draw_text(rl.text_format_int("FPS: unlimited (%i)", rl.get_fps()), 10, 10, 20, rl.DARKGRAY)
        else:
            rl.draw_text(rl.text_format_int_int("FPS: %i (target: %i)", rl.get_fps(), current_fps), 10, 10, 20, rl.DARKGRAY)

        rl.draw_text(rl.text_format_float("Frame time: %.2f ms", rl.get_frame_time()), 10, 30, 20, rl.DARKGRAY)
        rl.draw_text("Use the scroll wheel to change the fps limit, r to reset", 10, 50, 20, rl.DARKGRAY)
        rl.draw_text("FUNC: x += GetFrameTime()*speed", 10, 90, 20, rl.RED)
        rl.draw_text("FUNC: x += speed", 10, 240, 20, rl.BLUE)

    return 0
