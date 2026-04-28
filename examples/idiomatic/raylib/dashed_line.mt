module examples.idiomatic.raylib.dashed_line

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const line_color_count: i32 = 8

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Dashed Line")
    defer rl.close_window()

    let start_position = rl.Vector2(x = 20.0, y = 50.0)
    var end_position = rl.Vector2(x = 780.0, y = 400.0)
    var dash_length: f32 = 25.0
    var blank_length: f32 = 15.0
    var colors = zero[array[rl.Color, 8]]()
    colors[0] = rl.RED
    colors[1] = rl.ORANGE
    colors[2] = rl.GOLD
    colors[3] = rl.GREEN
    colors[4] = rl.BLUE
    colors[5] = rl.VIOLET
    colors[6] = rl.PINK
    colors[7] = rl.BLACK
    var color_index = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        end_position = rl.get_mouse_position()

        if rl.is_key_down(rl.KeyboardKey.KEY_UP):
            dash_length += 1.0
        if rl.is_key_down(rl.KeyboardKey.KEY_DOWN) and dash_length > 1.0:
            dash_length -= 1.0
        if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT):
            blank_length += 1.0
        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT) and blank_length > 1.0:
            blank_length -= 1.0
        if rl.is_key_pressed(rl.KeyboardKey.KEY_C):
            color_index = (color_index + 1) % line_color_count

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_line_dashed(start_position, end_position, cast[i32](dash_length), cast[i32](blank_length), colors[color_index])

        rl.draw_rectangle(5, 5, 265, 95, rl.fade(rl.SKYBLUE, 0.5))
        rl.draw_rectangle_lines(5, 5, 265, 95, rl.BLUE)
        rl.draw_text("CONTROLS:", 15, 15, 10, rl.BLACK)
        rl.draw_text("UP/DOWN: Change Dash Length", 15, 35, 10, rl.BLACK)
        rl.draw_text("LEFT/RIGHT: Change Space Length", 15, 55, 10, rl.BLACK)
        rl.draw_text("C: Cycle Color", 15, 75, 10, rl.BLACK)
        rl.draw_text(rl.text_format_f32_f32("Dash: %.0f | Space: %.0f", dash_length, blank_length), 15, 115, 10, rl.DARKGRAY)
        rl.draw_fps(screen_width - 80, 10)

    return 0
