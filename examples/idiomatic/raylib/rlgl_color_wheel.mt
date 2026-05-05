module examples.idiomatic.raylib.rlgl_color_wheel

import std.raygui as gui
import std.raylib as rl
import std.raylib.math as math
import std.rlgl as rlgl

const screen_width: int = 800
const screen_height: int = 450
const points_min: int = 3
const points_max: int = 256


def angle_fraction(center: rl.Vector2, circle_position: rl.Vector2, point_scale: float) -> float:
    let reference = rl.Vector2(x = 0.0, y = -point_scale)
    let relative = center.subtract(circle_position)
    return (reference.angle(relative) / rl.PI + 1.0) / 2.0


def clamp_handle_position(center: rl.Vector2, circle_position: rl.Vector2, point_scale: float) -> rl.Vector2:
    let distance = center.distance(circle_position) / point_scale
    if distance <= 1.0:
        return circle_position

    let angle = angle_fraction(center, circle_position, point_scale)
    return rl.Vector2(
        x = math.sin(angle * (rl.PI * 2.0)) * point_scale,
        y = -math.cos(angle * (rl.PI * 2.0)) * point_scale,
    ).add(center)


def main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(screen_width, screen_height, "Milk Tea rlgl Color Wheel")
    defer rl.close_window()

    var triangle_count: int = 64
    var point_scale: float = 150.0
    var value: float = 1.0

    let center = rl.Vector2(x = screen_width / 2.0, y = screen_height / 2.0)
    var circle_position = center
    var color = rl.Color(r = 255, g = 255, b = 255, a = 255)
    var slider_clicked = false
    var setting_color = false
    var render_type: int = rlgl.RL_TRIANGLES

    rl.set_target_fps(60)

    while not rl.window_should_close():
        triangle_count += int<-rl.get_mouse_wheel_move()
        if triangle_count < points_min:
            triangle_count = points_min
        if triangle_count > points_max:
            triangle_count = points_max

        let slider_rectangle = rl.Rectangle(x = 42.0, y = 125.0, width = 64.0, height = 16.0)
        let mouse_position = rl.get_mouse_position()
        let slider_hover = mouse_position.x >= slider_rectangle.x and mouse_position.y >= slider_rectangle.y and mouse_position.x < slider_rectangle.x + slider_rectangle.width and mouse_position.y < slider_rectangle.y + slider_rectangle.height

        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT_CONTROL) and rl.is_key_down(rl.KeyboardKey.KEY_C):
            if rl.is_key_pressed(rl.KeyboardKey.KEY_C):
                rl.set_clipboard_text(rl.text_format_int_int_int("#%02X%02X%02X", int<-color.r, int<-color.g, int<-color.b))

        if rl.is_key_down(rl.KeyboardKey.KEY_UP):
            point_scale *= 1.025
            if point_scale > float<-screen_height / 2.0:
                point_scale = float<-screen_height / 2.0
            else:
                circle_position = circle_position.subtract(center).multiply(rl.Vector2(x = 1.025, y = 1.025)).add(center)

        if rl.is_key_down(rl.KeyboardKey.KEY_DOWN):
            point_scale *= 0.975
            if point_scale < 32.0:
                point_scale = 32.0
            else:
                circle_position = circle_position.subtract(center).multiply(rl.Vector2(x = 0.975, y = 0.975)).add(center)
                circle_position = clamp_handle_position(center, circle_position, point_scale)

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT) and center.distance(mouse_position) <= point_scale + 10.0:
            setting_color = true

        if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
            setting_color = false

        if slider_hover and rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            slider_clicked = true

        if slider_clicked and rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
            slider_clicked = false

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            render_type = rlgl.RL_LINES

        if rl.is_key_released(rl.KeyboardKey.KEY_SPACE):
            render_type = rlgl.RL_TRIANGLES

        if setting_color or slider_clicked:
            if setting_color:
                circle_position = mouse_position

            let distance = center.distance(circle_position) / point_scale
            let angle = angle_fraction(center, circle_position, point_scale)
            if setting_color and distance > 1.0:
                circle_position = clamp_handle_position(center, circle_position, point_scale)

            let angle_360 = angle * 360.0
            let saturation = math.clamp(distance, 0.0, 1.0)
            let value_actual = math.clamp(distance, 0.0, 1.0)
            color = rl.color_lerp(
                rl.Color(r = ubyte<-(value * 255.0), g = ubyte<-(value * 255.0), b = ubyte<-(value * 255.0), a = 255),
                rl.color_from_hsv(angle_360, saturation, 1.0),
                value_actual,
            )

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        rlgl.begin(render_type)
        for index in 0..triangle_count:
            let angle_offset = (rl.PI * 2.0) / float<-triangle_count
            let angle = angle_offset * float<-index
            let angle_offset_calculated = (float<-index + 1.0) * angle_offset
            let scale = rl.Vector2(x = point_scale, y = point_scale)

            let offset = rl.Vector2(x = math.sin(angle), y = -math.cos(angle)).multiply(scale)
            let offset2 = rl.Vector2(x = math.sin(angle_offset_calculated), y = -math.cos(angle_offset_calculated)).multiply(scale)
            let position = center.add(offset)
            let position2 = center.add(offset2)

            let angle_non_radian = angle / (2.0 * rl.PI) * 360.0
            let angle_non_radian_offset = angle_offset / (2.0 * rl.PI) * 360.0
            let current_color = rl.color_from_hsv(angle_non_radian, 1.0, 1.0)
            let offset_color = rl.color_from_hsv(angle_non_radian + angle_non_radian_offset, 1.0, 1.0)

            if render_type == rlgl.RL_TRIANGLES:
                rlgl.color_4ub(current_color.r, current_color.g, current_color.b, current_color.a)
                rlgl.vertex_2f(position.x, position.y)
                rlgl.color_4f(value, value, value, 1.0)
                rlgl.vertex_2f(center.x, center.y)
                rlgl.color_4ub(offset_color.r, offset_color.g, offset_color.b, offset_color.a)
                rlgl.vertex_2f(position2.x, position2.y)
            elif render_type == rlgl.RL_LINES:
                rlgl.color_4ub(current_color.r, current_color.g, current_color.b, current_color.a)
                rlgl.vertex_2f(position.x, position.y)
                rlgl.color_4ub(rl.WHITE.r, rl.WHITE.g, rl.WHITE.b, rl.WHITE.a)
                rlgl.vertex_2f(center.x, center.y)

                rlgl.vertex_2f(center.x, center.y)
                rlgl.color_4ub(offset_color.r, offset_color.g, offset_color.b, offset_color.a)
                rlgl.vertex_2f(position2.x, position2.y)

                rlgl.vertex_2f(position2.x, position2.y)
                rlgl.color_4ub(current_color.r, current_color.g, current_color.b, current_color.a)
                rlgl.vertex_2f(position.x, position.y)
        rlgl.end()

        var handle_color = rl.BLACK
        if center.distance(circle_position) / point_scale <= 0.5 and value <= 0.5:
            handle_color = rl.DARKGRAY

        rl.draw_circle_lines_v(circle_position, 4.0, handle_color)
        rl.draw_rectangle_v(rl.Vector2(x = 8.0, y = 8.0), rl.Vector2(x = 64.0, y = 64.0), color)
        rl.draw_rectangle_lines_ex(rl.Rectangle(x = 8.0, y = 8.0, width = 64.0, height = 64.0), 2.0, rl.color_lerp(color, rl.BLACK, 0.5))

        rl.draw_text(
            rl.text_format_int_int_int_int(
                "%02X%02X%02X (%d)",
                int<-color.r,
                int<-color.g,
                int<-color.b,
                int<-color.a,
            ),
            8,
            80,
            20,
            rl.DARKGRAY,
        )

        var copy_color = rl.DARKGRAY
        var copy_offset = 0
        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT_CONTROL) and rl.is_key_down(rl.KeyboardKey.KEY_C):
            copy_color = rl.DARKGREEN
            copy_offset = 4

        rl.draw_text("press ctrl+c to copy!", 8, 425 - copy_offset, 20, copy_color)
        rl.draw_text(rl.text_format_int("triangle count: %d", triangle_count), 8, 395, 20, rl.DARKGRAY)

        gui.slider_bar(slider_rectangle, "value: ", "", inout value, 0.0, 1.0)
        rl.draw_fps(80, 8)

    return 0
