module examples.raylib.shapes.shapes_splines_drawing

import std.c.raygui as gui
import std.c.raylib as rl

struct ControlPoint:
    start: rl.Vector2
    end: rl.Vector2

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
const window_title: cstr = c"raylib [shapes] example - splines drawing"
const spline_thickness_format: cstr = c"Spline thickness: %i"
const point_format: cstr = c"[%.0f, %.0f]"
const spline_type_label: cstr = c"Spline kind:"
const spline_type_options: cstr = c"LINEAR;BSPLINE;CATMULLROM;BEZIER"
const show_point_helpers_text: cstr = c"Show point helpers"
const empty_text: cstr = c""


def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var points = zero[array[rl.Vector2, 32]]
    points[0] = rl.Vector2(x = 50.0, y = 400.0)
    points[1] = rl.Vector2(x = 160.0, y = 220.0)
    points[2] = rl.Vector2(x = 340.0, y = 380.0)
    points[3] = rl.Vector2(x = 520.0, y = 60.0)
    points[4] = rl.Vector2(x = 710.0, y = 260.0)

    var points_interleaved = zero[array[rl.Vector2, 94]]
    var control_points = zero[array[ControlPoint, 31]]

    var point_count = 5
    var selected_point = -1
    var focused_point = -1
    var selected_control_segment = -1
    var selected_control_side = control_start
    var focused_control_segment = -1
    var focused_control_side = control_start

    for index in 0..point_count - 1:
        control_points[index].start = rl.Vector2(x = points[index].x + 50.0, y = points[index].y)
        control_points[index].end = rl.Vector2(x = points[index + 1].x - 50.0, y = points[index + 1].y)

    var spline_thickness: f32 = 8.0
    var spline_type_active = spline_linear
    var spline_type_edit_mode = false
    var spline_helpers_active = true

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let mouse_position = rl.GetMousePosition()

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            if point_count < max_spline_points:
                points[point_count] = mouse_position
                let segment = point_count - 1
                control_points[segment].start = rl.Vector2(x = points[segment].x + 50.0, y = points[segment].y)
                control_points[segment].end = rl.Vector2(x = points[segment + 1].x - 50.0, y = points[segment + 1].y)
                point_count += 1

        if selected_point == -1:
            if spline_type_active != spline_bezier or selected_control_segment == -1:
                focused_point = -1
                for index in 0..point_count:
                    if rl.CheckCollisionPointCircle(mouse_position, points[index], 8.0):
                        focused_point = index
                        break

                if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
                    selected_point = focused_point

        if selected_point >= 0:
            points[selected_point] = mouse_position
            if rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT):
                selected_point = -1

        if spline_type_active == spline_bezier:
            if focused_point == -1:
                if selected_control_segment == -1:
                    focused_control_segment = -1
                    for index in 0..point_count - 1:
                        if rl.CheckCollisionPointCircle(mouse_position, control_points[index].start, 6.0):
                            focused_control_segment = index
                            focused_control_side = control_start
                            break

                        if rl.CheckCollisionPointCircle(mouse_position, control_points[index].end, 6.0):
                            focused_control_segment = index
                            focused_control_side = control_end
                            break

                    if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
                        selected_control_segment = focused_control_segment
                        selected_control_side = focused_control_side

                if selected_control_segment >= 0:
                    if selected_control_side == control_start:
                        control_points[selected_control_segment].start = mouse_position
                    else:
                        control_points[selected_control_segment].end = mouse_position

                    focused_control_segment = selected_control_segment
                    focused_control_side = selected_control_side

                    if rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT):
                        selected_control_segment = -1
            else:
                focused_control_segment = -1
        else:
            focused_control_segment = -1
            selected_control_segment = -1

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_ONE):
            spline_type_active = spline_linear
            selected_control_segment = -1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_TWO):
            spline_type_active = spline_basis
            selected_control_segment = -1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_THREE):
            spline_type_active = spline_catmull_rom
            selected_control_segment = -1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_FOUR):
            spline_type_active = spline_bezier

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        if spline_type_active == spline_linear:
            rl.DrawSplineLinear(ptr_of(points[0]), point_count, spline_thickness, rl.RED)
        elif spline_type_active == spline_basis:
            rl.DrawSplineBasis(ptr_of(points[0]), point_count, spline_thickness, rl.RED)
        elif spline_type_active == spline_catmull_rom:
            rl.DrawSplineCatmullRom(ptr_of(points[0]), point_count, spline_thickness, rl.RED)
        elif spline_type_active == spline_bezier:
            for index in 0..point_count - 1:
                points_interleaved[3 * index] = points[index]
                points_interleaved[3 * index + 1] = control_points[index].start
                points_interleaved[3 * index + 2] = control_points[index].end

            points_interleaved[3 * (point_count - 1)] = points[point_count - 1]
            rl.DrawSplineBezierCubic(ptr_of(points_interleaved[0]), 3 * (point_count - 1) + 1, spline_thickness, rl.RED)

            for index in 0..point_count - 1:
                rl.DrawCircleV(control_points[index].start, 6.0, rl.GOLD)
                rl.DrawCircleV(control_points[index].end, 6.0, rl.GOLD)

                if focused_control_segment == index and focused_control_side == control_start:
                    rl.DrawCircleV(control_points[index].start, 8.0, rl.GREEN)
                elif focused_control_segment == index and focused_control_side == control_end:
                    rl.DrawCircleV(control_points[index].end, 8.0, rl.GREEN)

                rl.DrawLineEx(points[index], control_points[index].start, 1.0, rl.LIGHTGRAY)
                rl.DrawLineEx(points[index + 1], control_points[index].end, 1.0, rl.LIGHTGRAY)
                rl.DrawLineV(points[index], control_points[index].start, rl.GRAY)
                rl.DrawLineV(control_points[index].end, points[index + 1], rl.GRAY)

        if spline_helpers_active:
            for index in 0..point_count:
                var helper_radius: f32 = 8.0
                var helper_color = rl.DARKBLUE
                if focused_point == index:
                    helper_radius = 12.0
                    helper_color = rl.BLUE

                rl.DrawCircleLinesV(points[index], helper_radius, helper_color)

                if spline_type_active != spline_linear:
                    if spline_type_active != spline_bezier:
                        if index < point_count - 1:
                            rl.DrawLineV(points[index], points[index + 1], rl.GRAY)

                rl.DrawText(rl.TextFormat(point_format, points[index].x, points[index].y), i32<-points[index].x, i32<-points[index].y + 10, 10, rl.BLACK)

        if spline_type_edit_mode or selected_point != -1 or selected_control_segment != -1:
            gui.GuiLock()

        gui.GuiLabel(gui.Rectangle(x = 12.0, y = 62.0, width = 140.0, height = 24.0), rl.TextFormat(spline_thickness_format, i32<-spline_thickness))
        gui.GuiSliderBar(gui.Rectangle(x = 12.0, y = 84.0, width = 140.0, height = 16.0), empty_text, empty_text, ptr_of(spline_thickness), 1.0, 40.0)
        gui.GuiCheckBox(gui.Rectangle(x = 12.0, y = 110.0, width = 20.0, height = 20.0), show_point_helpers_text, ptr_of(spline_helpers_active))

        if spline_type_edit_mode:
            gui.GuiUnlock()

        gui.GuiLabel(gui.Rectangle(x = 12.0, y = 10.0, width = 140.0, height = 24.0), spline_type_label)
        if gui.GuiDropdownBox(gui.Rectangle(x = 12.0, y = 32.0, width = 140.0, height = 28.0), spline_type_options, ptr_of(spline_type_active), spline_type_edit_mode) != 0:
            spline_type_edit_mode = not spline_type_edit_mode

        gui.GuiUnlock()

    return 0
