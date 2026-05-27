import std.raygui as gui
import std.raylib as rl
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_SPLINE_POINTS: int = 32
const MAX_CONTROL_SEGMENTS: int = 31
const MAX_INTERLEAVED_POINTS: int = 94
const SPLINE_LINEAR: int = 0
const SPLINE_BASIS: int = 1
const SPLINE_CATMULLROM: int = 2
const SPLINE_BEZIER: int = 3


struct ControlPoint:
    start: rl.Vector2
    end: rl.Vector2


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - splines drawing")
    defer rl.close_window()

    var points: array[rl.Vector2, MAX_SPLINE_POINTS] = array[rl.Vector2, MAX_SPLINE_POINTS](
        rl.Vector2(x = 50.0, y = 400.0),
        rl.Vector2(x = 160.0, y = 220.0),
        rl.Vector2(x = 340.0, y = 380.0),
        rl.Vector2(x = 520.0, y = 60.0),
        rl.Vector2(x = 710.0, y = 260.0),
        zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2], zero[rl.Vector2]
    )
    var points_interleaved: array[rl.Vector2, MAX_INTERLEAVED_POINTS] = zero[array[rl.Vector2, MAX_INTERLEAVED_POINTS]]

    var point_count = 5
    var selected_point = -1
    var focused_point = -1
    var selected_control_segment = -1
    var selected_control_is_start = true
    var focused_control_segment = -1
    var focused_control_is_start = true

    var control: array[ControlPoint, MAX_CONTROL_SEGMENTS] = zero[array[ControlPoint, MAX_CONTROL_SEGMENTS]]
    var index = 0
    while index < point_count - 1:
        control[index].start = rl.Vector2(x = points[index].x + 50.0, y = points[index].y)
        control[index].end = rl.Vector2(x = points[index + 1].x - 50.0, y = points[index + 1].y)
        index += 1

    var spline_thickness: float = 8.0
    var spline_type_active = SPLINE_LINEAR
    var spline_type_edit_mode = false
    var spline_helpers_active = true

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse = rl.get_mouse_position()

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_RIGHT) and point_count < MAX_SPLINE_POINTS:
            points[point_count] = mouse
            let segment = point_count - 1
            control[segment].start = rl.Vector2(x = points[segment].x + 50.0, y = points[segment].y)
            control[segment].end = rl.Vector2(x = points[segment + 1].x - 50.0, y = points[segment + 1].y)
            point_count += 1

        if selected_point == -1 and (spline_type_active != SPLINE_BEZIER or selected_control_segment == -1):
            focused_point = -1
            index = 0
            while index < point_count:
                if rl.check_collision_point_circle(mouse, points[index], 8.0):
                    focused_point = index
                    break
                index += 1

            if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
                selected_point = focused_point

        if selected_point >= 0:
            points[selected_point] = mouse
            if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
                selected_point = -1

        if spline_type_active == SPLINE_BEZIER and focused_point == -1:
            if selected_control_segment == -1:
                focused_control_segment = -1
                index = 0
                while index < point_count - 1:
                    if rl.check_collision_point_circle(mouse, control[index].start, 6.0):
                        focused_control_segment = index
                        focused_control_is_start = true
                        break
                    else if rl.check_collision_point_circle(mouse, control[index].end, 6.0):
                        focused_control_segment = index
                        focused_control_is_start = false
                        break
                    index += 1

                if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
                    selected_control_segment = focused_control_segment
                    selected_control_is_start = focused_control_is_start

            if selected_control_segment != -1:
                if selected_control_is_start:
                    control[selected_control_segment].start = mouse
                else:
                    control[selected_control_segment].end = mouse

                if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
                    selected_control_segment = -1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            spline_type_active = SPLINE_LINEAR
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            spline_type_active = SPLINE_BASIS
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            spline_type_active = SPLINE_CATMULLROM
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_FOUR):
            spline_type_active = SPLINE_BEZIER

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE) or rl.is_key_pressed(rl.KeyboardKey.KEY_TWO) or rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            selected_control_segment = -1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        if spline_type_active == SPLINE_LINEAR:
            rl.draw_spline_linear_ptr(ptr_of(points[0]), point_count, spline_thickness, rl.RED)
        else if spline_type_active == SPLINE_BASIS:
            rl.draw_spline_basis_ptr(ptr_of(points[0]), point_count, spline_thickness, rl.RED)
        else if spline_type_active == SPLINE_CATMULLROM:
            rl.draw_spline_catmull_rom_ptr(ptr_of(points[0]), point_count, spline_thickness, rl.RED)
        else:
            index = 0
            while index < point_count - 1:
                points_interleaved[3 * index] = points[index]
                points_interleaved[(3 * index) + 1] = control[index].start
                points_interleaved[(3 * index) + 2] = control[index].end
                index += 1

            points_interleaved[3 * (point_count - 1)] = points[point_count - 1]
            rl.draw_spline_bezier_cubic_ptr(ptr_of(points_interleaved[0]), (3 * (point_count - 1)) + 1, spline_thickness, rl.RED)

            index = 0
            while index < point_count - 1:
                rl.draw_circle_v(control[index].start, 6.0, rl.GOLD)
                rl.draw_circle_v(control[index].end, 6.0, rl.GOLD)
                if focused_control_segment == index and focused_control_is_start:
                    rl.draw_circle_v(control[index].start, 8.0, rl.GREEN)
                else if focused_control_segment == index and not focused_control_is_start:
                    rl.draw_circle_v(control[index].end, 8.0, rl.GREEN)
                rl.draw_line_ex(points[index], control[index].start, 1.0, rl.LIGHTGRAY)
                rl.draw_line_ex(points[index + 1], control[index].end, 1.0, rl.LIGHTGRAY)
                rl.draw_line_v(points[index], control[index].start, rl.GRAY)
                rl.draw_line_v(control[index].end, points[index + 1], rl.GRAY)
                index += 1

        if spline_helpers_active:
            index = 0
            while index < point_count:
                let helper_radius: float = if focused_point == index: 12.0 else: 8.0
                let helper_color = if focused_point == index: rl.BLUE else: rl.DARKBLUE
                rl.draw_circle_lines_v(points[index], helper_radius, helper_color)
                if spline_type_active != SPLINE_LINEAR and spline_type_active != SPLINE_BEZIER and index < point_count - 1:
                    rl.draw_line_v(points[index], points[index + 1], rl.GRAY)

                rl.draw_text(text.cstr_as_str(rl.text_format("[%.0f, %.0f]", points[index].x, points[index].y)), int<-points[index].x, int<-points[index].y + 10, 10, rl.BLACK)
                index += 1

        if spline_type_edit_mode or selected_point != -1 or selected_control_segment != -1:
            gui.lock()

        gui.label(rl.Rectangle(x = 12.0, y = 62.0, width = 140.0, height = 24.0), text.cstr_as_str(rl.text_format("Spline thickness: %i", int<-spline_thickness)))
        gui.slider_bar(rl.Rectangle(x = 12.0, y = 84.0, width = 140.0, height = 16.0), "", "", spline_thickness, 1.0, 40.0)
        gui.check_box(rl.Rectangle(x = 12.0, y = 110.0, width = 20.0, height = 20.0), "Show point helpers", spline_helpers_active)

        if spline_type_edit_mode:
            gui.unlock()

        gui.label(rl.Rectangle(x = 12.0, y = 10.0, width = 140.0, height = 24.0), "Spline type:")
        if gui.dropdown_box(rl.Rectangle(x = 12.0, y = 32.0, width = 140.0, height = 28.0), "LINEAR;BSPLINE;CATMULLROM;BEZIER", spline_type_active, spline_type_edit_mode) != 0:
            spline_type_edit_mode = not spline_type_edit_mode

        gui.unlock()
        rl.end_drawing()

    return 0
