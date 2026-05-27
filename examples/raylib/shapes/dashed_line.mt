import std.raylib as rl
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const LINE_COLOR_COUNT: int = 8


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - dashed line")
    defer rl.close_window()

    let line_start_position = rl.Vector2(x = 20.0, y = 50.0)
    var line_end_position = rl.Vector2(x = 780.0, y = 400.0)
    var dash_length: float = 25.0
    var blank_length: float = 15.0
    let line_colors = array[rl.Color, LINE_COLOR_COUNT](rl.RED, rl.ORANGE, rl.GOLD, rl.GREEN, rl.BLUE, rl.VIOLET, rl.PINK, rl.BLACK)
    var color_index = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        line_end_position = rl.get_mouse_position()

        if rl.is_key_down(rl.KeyboardKey.KEY_UP):
            dash_length += 1.0
        if rl.is_key_down(rl.KeyboardKey.KEY_DOWN) and dash_length > 1.0:
            dash_length -= 1.0

        if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT):
            blank_length += 1.0
        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT) and blank_length > 1.0:
            blank_length -= 1.0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_C):
            color_index = (color_index + 1) % LINE_COLOR_COUNT

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_line_dashed(line_start_position, line_end_position, int<-dash_length, int<-blank_length, line_colors[color_index])

        rl.draw_rectangle(5, 5, 265, 95, rl.fade(rl.SKYBLUE, 0.5))
        rl.draw_rectangle_lines(5, 5, 265, 95, rl.BLUE)
        rl.draw_text("CONTROLS:", 15, 15, 10, rl.BLACK)
        rl.draw_text("UP/DOWN: Change Dash Length", 15, 35, 10, rl.BLACK)
        rl.draw_text("LEFT/RIGHT: Change Space Length", 15, 55, 10, rl.BLACK)
        rl.draw_text("C: Cycle Color", 15, 75, 10, rl.BLACK)
        let dash_length_text = text.cstr_as_str(rl.text_format("Dash: %.0f | Space: %.0f", dash_length, blank_length))
        rl.draw_text(dash_length_text, 15, 115, 10, rl.DARKGRAY)
        rl.draw_fps(SCREEN_WIDTH - 80, 10)
        rl.end_drawing()

    return 0
