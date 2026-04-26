module examples.idiomatic.raylib.input_multitouch

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const max_touch_points: i32 = 10
const touch_radius: f32 = 34.0

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Multitouch")
    defer rl.close_window()

    rl.set_target_fps(60)

    while not rl.window_should_close():
        var touch_count = rl.get_touch_point_count()
        if touch_count > max_touch_points:
            touch_count = max_touch_points

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        for index in range(0, touch_count):
            let touch_position = rl.get_touch_position(index)
            if touch_position.x > 0.0 and touch_position.y > 0.0:
                rl.draw_circle_v(touch_position, touch_radius, rl.ORANGE)

        rl.draw_text("touch the screen at multiple locations to get multiple balls", 10, 10, 20, rl.DARKGRAY)

    return 0
