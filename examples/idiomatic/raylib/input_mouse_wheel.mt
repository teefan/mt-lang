module examples.idiomatic.raylib.input_mouse_wheel

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Input Mouse Wheel")
    defer rl.close_window()

    var box_position_y = screen_height / 2 - 40
    let scroll_speed: f32 = 4.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        box_position_y -= cast[i32](rl.get_mouse_wheel_move() * scroll_speed)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_rectangle(screen_width / 2 - 40, box_position_y, 80, 80, rl.MAROON)
        rl.draw_text("Use mouse wheel to move the cube up and down!", 10, 10, 20, rl.GRAY)
        rl.draw_text(rl.text_format_i32("Box position Y: %03i", box_position_y), 10, 40, 20, rl.LIGHTGRAY)

    return 0
