module examples.idiomatic.raylib.splines_drawing

import std.raygui as gui
import std.raylib as rl
import std.mem.heap as heap

struct ControlPoint:
    start: rl.Vector2
    finish: rl.Vector2

const screen_width: i32 = 800
const screen_height: i32 = 450
const max_spline_points: i32 = 32
const max_bezier_points: i32 = 94
const spline_linear: i32 = 0
const spline_basis: i32 = 1
const spline_catmull_rom: i32 = 2
const spline_bezier: i32 = 3
const control_start: i32 = 0
const control_end: i32 = 1

def main() -> i32:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(screen_width, screen_height, "Milk Tea Splines Drawing")
    defer rl.close_window()

    let point_storage = heap.must_alloc_zeroed[rl.Vector2](cast[usize](max_spline_points))
    defer heap.release(point_storage)
    var points = span[rl.Vector2](data = point_storage, len = cast[usize](max_spline_points))
    points[0] = rl.Vector2(x = 50.0, y = 400.0)
    points[1] = rl.Vector2(x = 160.0, y = 220.0)
    points[2] = rl.Vector2(x = 340.0, y = 380.0)
    points[3] = rl.Vector2(x = 520.0, y = 60.0)
    points[4] = rl.Vector2(x = 710.0, y = 260.0)

    let bezier_storage = heap.must_alloc_zeroed[rl.Vector2](cast[usize](max_bezier_points))
    defer heap.release(bezier_storage)
    var bezier_points = span[rl.Vector2](data = bezier_storage, len = cast[usize](max_bezier_points))
    var control_points = zero[array[ControlPoint, 31]]()
    var point_count = 5
    var selected_point = -1
    var focused_point = -1
    var selected_control_segment = -1
    var selected_control_side = control_start
    var focused_control_segment = -1
    var focused_control_side = control_start

    for index in range(0, point_count - 1):
        control_points[index].start = rl.Vector2(x = points[index].x + 50.0, y = points[index].y)
        control_points[index].finish = rl.Vector2(x = points[index + 1].x - 50.0, y = points[index + 1].y)

    var spline_thickness: f32 = 8.0
    var spline_type_active = spline_linear
    var spline_type_edit_mode = false
    var spline_helpers_active = true

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse_position = rl.get_mouse_position()

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            if point_count < max_spline_points:
                points[point_count] = mouse_position
                let segment = point_count - 1
                control_points[segment].start = rl.Vector2(x = points[segment].x + 50.0, y = points[segment].y)
                control_points[segment].finish = rl.Vector2(x = points[segment + 1].x - 50.0, y = points[segment + 1].y)
                point_count += 1

        if selected_point == -1:
            if spline_type_active != spline_bezier or selected_control_segment == -1:
                focused_point = -1
                for index in range(0, point_count):
                    if rl.check_collision_point_circle(mouse_position, points[index], 8.0):
                        focused_point = index
                        break

                if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
                    selected_point = focused_point

        if selected_point >= 0:
            points[selected_point] = mouse_position
            if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
                selected_point = -1

        if spline_type_active == spline_bezier:
            if focused_point == -1:
                if selected_control_segment == -1:
                    focused_control_segment = -1
                    for index in range(0, point_count - 1):
                        if rl.check_collision_point_circle(mouse_position, control_points[index].start, 6.0):
                            focused_control_segment = index
                            focused_control_side = control_start
                            break

                        if rl.check_collision_point_circle(mouse_position, control_points[index].finish, 6.0):
                            focused_control_segment = index
                            focused_control_side = control_end
                            break

                    if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
                        selected_control_segment = focused_control_segment
                        selected_control_side = focused_control_side

                if selected_control_segment >= 0:
                    if selected_control_side == control_start:
                        control_points[selected_control_segment].start = mouse_position
                    else:
                        control_points[selected_control_segment].finish = mouse_position

                    focused_control_segment = selected_control_segment
                    focused_control_side = selected_control_side

                    if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
                        selected_control_segment = -1
            else:
                focused_control_segment = -1
        else:
            focused_control_segment = -1
            selected_control_segment = -1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            spline_type_active = spline_linear
            selected_control_segment = -1
        elif rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            spline_type_active = spline_basis
            selected_control_segment = -1
        elif rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            spline_type_active = spline_catmull_rom
            selected_control_segment = -1
        elif rl.is_key_pressed(rl.KeyboardKey.KEY_FOUR):
            spline_type_active = spline_bezier

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        let points_view = span[rl.Vector2](data = point_storage, len = cast[usize](point_count))
        if spline_type_active == spline_linear:
            rl.draw_spline_linear(points_view, spline_thickness, rl.RED)
        elif spline_type_active == spline_basis:
            rl.draw_spline_basis(points_view, spline_thickness, rl.RED)
        elif spline_type_active == spline_catmull_rom:
            rl.draw_spline_catmull_rom(points_view, spline_thickness, rl.RED)
        elif spline_type_active == spline_bezier:
            for index in range(0, point_count - 1):
                bezier_points[3 * index] = points[index]
                bezier_points[3 * index + 1] = control_points[index].start
                bezier_points[3 * index + 2] = control_points[index].finish

            let bezier_count = 3 * (point_count - 1) + 1
            bezier_points[bezier_count - 1] = points[point_count - 1]
            rl.draw_spline_bezier_cubic(span[rl.Vector2](data = bezier_storage, len = cast[usize](bezier_count)), spline_thickness, rl.RED)

            for index in range(0, point_count - 1):
                rl.draw_circle_v(control_points[index].start, 6.0, rl.GOLD)
                rl.draw_circle_v(control_points[index].finish, 6.0, rl.GOLD)

                if focused_control_segment == index and focused_control_side == control_start:
                    rl.draw_circle_v(control_points[index].start, 8.0, rl.GREEN)
                elif focused_control_segment == index and focused_control_side == control_end:
                    rl.draw_circle_v(control_points[index].finish, 8.0, rl.GREEN)

                rl.draw_line_ex(points[index], control_points[index].start, 1.0, rl.LIGHTGRAY)
                rl.draw_line_ex(points[index + 1], control_points[index].finish, 1.0, rl.LIGHTGRAY)
                rl.draw_line_v(points[index], control_points[index].start, rl.GRAY)
                rl.draw_line_v(control_points[index].finish, points[index + 1], rl.GRAY)

        if spline_helpers_active:
            for index in range(0, point_count):
                var helper_radius: f32 = 8.0
                var helper_color = rl.DARKBLUE
                if focused_point == index:
                    helper_radius = 12.0
                    helper_color = rl.BLUE

                rl.draw_circle_lines_v(points[index], helper_radius, helper_color)

                if spline_type_active != spline_linear:
                    if spline_type_active != spline_bezier:
                        if index < point_count - 1:
                            rl.draw_line_v(points[index], points[index + 1], rl.GRAY)

                rl.draw_text(rl.text_format_f32_f32("[%.0f, %.0f]", points[index].x, points[index].y), cast[i32](points[index].x), cast[i32](points[index].y) + 10, 10, rl.BLACK)

        if spline_type_edit_mode or selected_point != -1 or selected_control_segment != -1:
            gui.lock()

        gui.label(rl.Rectangle(x = 12.0, y = 62.0, width = 140.0, height = 24.0), rl.text_format_i32("Spline thickness: %i", cast[i32](spline_thickness)))
        gui.slider_bar(rl.Rectangle(x = 12.0, y = 84.0, width = 140.0, height = 16.0), "", "", inout spline_thickness, 1.0, 40.0)
        gui.check_box(rl.Rectangle(x = 12.0, y = 110.0, width = 20.0, height = 20.0), "Show point helpers", inout spline_helpers_active)

        if spline_type_edit_mode:
            gui.unlock()

        gui.label(rl.Rectangle(x = 12.0, y = 10.0, width = 140.0, height = 24.0), "Spline type:")
        if gui.dropdown_box(rl.Rectangle(x = 12.0, y = 32.0, width = 140.0, height = 28.0), "LINEAR;BSPLINE;CATMULLROM;BEZIER", inout spline_type_active, spline_type_edit_mode) != 0:
            spline_type_edit_mode = not spline_type_edit_mode

        gui.unlock()

    return 0
