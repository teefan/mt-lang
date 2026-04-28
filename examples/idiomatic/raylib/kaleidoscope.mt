module examples.idiomatic.raylib.kaleidoscope

import std.raygui as gui
import std.raylib as rl
import std.raylib.math as math

struct Line:
    start: rl.Vector2
    finish: rl.Vector2

const max_draw_lines: i32 = 8192
const screen_width: i32 = 800
const screen_height: i32 = 450

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Kaleidoscope")
    defer rl.close_window()

    var lines = zero[array[Line, 8192]]()
    let symmetry: i32 = 6
    let angle = 360.0 / cast[f32](symmetry)
    let thickness: f32 = 3.0
    let reset_button_rec = rl.Rectangle(x = screen_width - 55.0, y = 5.0, width = 50.0, height = 25.0)
    let back_button_rec = rl.Rectangle(x = screen_width - 55.0, y = screen_height - 30.0, width = 25.0, height = 25.0)
    let next_button_rec = rl.Rectangle(x = screen_width - 30.0, y = screen_height - 30.0, width = 25.0, height = 25.0)
    var mouse_pos = math.Vector2.zero()
    var prev_mouse_pos = math.Vector2.zero()
    let scale_vector = rl.Vector2(x = 1.0, y = -1.0)
    let offset = rl.Vector2(x = screen_width / 2.0, y = screen_height / 2.0)
    let camera = rl.Camera2D(offset = offset, target = math.Vector2.zero(), rotation = 0.0, zoom = 1.0)

    var current_line_counter = 0
    var total_line_counter = 0
    var reset_button_clicked = false
    var back_button_clicked = false
    var next_button_clicked = false

    rl.set_target_fps(20)

    while not rl.window_should_close():
        prev_mouse_pos = mouse_pos
        mouse_pos = rl.get_mouse_position()

        let base_line_start = mouse_pos.subtract(offset)
        let base_line_end = prev_mouse_pos.subtract(offset)

        if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
            if not rl.check_collision_point_rec(mouse_pos, reset_button_rec):
                if not rl.check_collision_point_rec(mouse_pos, back_button_rec):
                    if not rl.check_collision_point_rec(mouse_pos, next_button_rec):
                        var line_start = base_line_start
                        var line_end = base_line_end

                        for _ in range(0, symmetry):
                            if total_line_counter >= max_draw_lines - 1:
                                break

                            line_start = line_start.rotate(angle * math.deg2rad)
                            line_end = line_end.rotate(angle * math.deg2rad)

                            lines[total_line_counter] = Line(start = line_start, finish = line_end)
                            lines[total_line_counter + 1] = Line(start = line_start.multiply(scale_vector), finish = line_end.multiply(scale_vector))

                            total_line_counter += 2
                            current_line_counter = total_line_counter

        if reset_button_clicked:
            current_line_counter = 0
            total_line_counter = 0

        if back_button_clicked and current_line_counter > 0:
            current_line_counter -= 1

        if next_button_clicked and current_line_counter < max_draw_lines and current_line_counter + 1 <= total_line_counter:
            current_line_counter += 1

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.begin_mode_2d(camera)

        for _ in range(0, symmetry):
            var index = 0
            while index < current_line_counter:
                rl.draw_line_ex(lines[index].start, lines[index].finish, thickness, rl.BLACK)
                rl.draw_line_ex(lines[index + 1].start, lines[index + 1].finish, thickness, rl.BLACK)
                index += 2

        rl.end_mode_2d()

        if current_line_counter - 1 < 0:
            gui.disable()

        back_button_clicked = gui.button(back_button_rec, "<") != 0
        gui.enable()

        if current_line_counter + 1 > total_line_counter:
            gui.disable()

        next_button_clicked = gui.button(next_button_rec, ">") != 0
        gui.enable()
        reset_button_clicked = gui.button(reset_button_rec, "Reset") != 0

        rl.draw_text(rl.text_format_i32_i32("LINES: %i/%i", current_line_counter, max_draw_lines), 10, screen_height - 30, 20, rl.MAROON)
        rl.draw_fps(10, 10)

    return 0
