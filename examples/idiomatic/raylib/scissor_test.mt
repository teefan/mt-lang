module examples.idiomatic.raylib.scissor_test

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const scissor_width: i32 = 300
const scissor_height: i32 = 300
const scissor_half_width: i32 = 150
const scissor_half_height: i32 = 150

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Scissor Test")
    defer rl.close_window()

    var scissor_x = 0
    var scissor_y = 0
    var scissor_mode = true

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_S):
            scissor_mode = not scissor_mode

        scissor_x = rl.get_mouse_x() - scissor_half_width
        scissor_y = rl.get_mouse_y() - scissor_half_height
        let scissor_area = rl.Rectangle(x = scissor_x, y = scissor_y, width = scissor_width, height = scissor_height)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        if scissor_mode:
            rl.begin_scissor_mode(scissor_x, scissor_y, scissor_width, scissor_height)

        rl.draw_rectangle(0, 0, rl.get_screen_width(), rl.get_screen_height(), rl.RED)
        rl.draw_text("Move the mouse around to reveal this text!", 190, 200, 20, rl.LIGHTGRAY)

        if scissor_mode:
            rl.end_scissor_mode()

        rl.draw_rectangle_lines_ex(scissor_area, 1.0, rl.BLACK)
        rl.draw_text("Press S to toggle scissor test", 10, 10, 20, rl.BLACK)

    return 0