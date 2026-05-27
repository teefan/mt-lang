import std.math as math
import std.raygui as gui
import std.raylib as rl
import std.raymath as rm
import std.rlgl as rlgl
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const POINTS_MIN: int = 3
const POINTS_MAX: int = 256
const TWO_PI: float = rl.PI * 2.0


function wheel_handle_position(center: rl.Vector2, point_scale: float, angle: float) -> rl.Vector2:
    return rm.vector2_add(
        rl.Vector2(
            x = float<-math.sin(double<-(angle * TWO_PI)) * point_scale,
            y = float<-(-math.cos(double<-(angle * TWO_PI)) * point_scale),
        ),
        center,
    )


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - rlgl color wheel")
    defer rl.close_window()

    var triangle_count = 64
    var point_scale: float = 150.0
    var value: float = 1.0

    let center = rl.Vector2(x = float<-SCREEN_WIDTH / 2.0, y = float<-SCREEN_HEIGHT / 2.0)
    var circle_position = center
    var color = rl.Color(r = 255, g = 255, b = 255, a = 255)
    var slider_clicked = false
    var setting_color = false
    var render_type = rlgl.RL_TRIANGLES

    rl.set_target_fps(60)

    while not rl.window_should_close():
        triangle_count = int<-rm.clamp(float<-triangle_count + rl.get_mouse_wheel_move(), float<-POINTS_MIN, float<-POINTS_MAX)

        let slider_rectangle = rl.Rectangle(x = 42.0, y = 16.0 + 64.0 + 45.0, width = 64.0, height = 16.0)
        let mouse_position = rl.get_mouse_position()
        let slider_hover = mouse_position.x >= slider_rectangle.x and mouse_position.y >= slider_rectangle.y and mouse_position.x < slider_rectangle.x + slider_rectangle.width and mouse_position.y < slider_rectangle.y + slider_rectangle.height

        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT_CONTROL) and rl.is_key_down(rl.KeyboardKey.KEY_C):
            if rl.is_key_pressed(rl.KeyboardKey.KEY_C):
                rl.set_clipboard_text(text.cstr_as_str(rl.text_format("#%02X%02X%02X", color.r, color.g, color.b)))

        if rl.is_key_down(rl.KeyboardKey.KEY_UP):
            point_scale *= 1.025
            if point_scale > float<-SCREEN_HEIGHT / 2.0:
                point_scale = float<-SCREEN_HEIGHT / 2.0
            else:
                circle_position = rm.vector2_add(rm.vector2_multiply(rm.vector2_subtract(circle_position, center), rl.Vector2(x = 1.025, y = 1.025)), center)

        if rl.is_key_down(rl.KeyboardKey.KEY_DOWN):
            point_scale *= 0.975
            if point_scale < 32.0:
                point_scale = 32.0
            else:
                circle_position = rm.vector2_add(rm.vector2_multiply(rm.vector2_subtract(circle_position, center), rl.Vector2(x = 0.975, y = 0.975)), center)

            let distance = rm.vector2_distance(center, circle_position) / point_scale
            let angle = ((rm.vector2_angle(rl.Vector2(x = 0.0, y = -point_scale), rm.vector2_subtract(center, circle_position)) / rl.PI) + 1.0) / 2.0
            if distance > 1.0:
                circle_position = wheel_handle_position(center, point_scale, angle)

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT) and rm.vector2_distance(rl.get_mouse_position(), center) <= point_scale + 10.0:
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
                circle_position = rl.get_mouse_position()

            let distance = rm.vector2_distance(center, circle_position) / point_scale
            let angle = ((rm.vector2_angle(rl.Vector2(x = 0.0, y = -point_scale), rm.vector2_subtract(center, circle_position)) / rl.PI) + 1.0) / 2.0
            if setting_color and distance > 1.0:
                circle_position = wheel_handle_position(center, point_scale, angle)

            let angle360 = angle * 360.0
            let value_actual = rm.clamp(distance, 0.0, 1.0)
            let channel = ubyte<-(int<-(value * 255.0))
            color = rl.color_lerp(
                rl.Color(r = channel, g = channel, b = channel, a = 255),
                rl.color_from_hsv(angle360, rm.clamp(distance, 0.0, 1.0), 1.0),
                value_actual,
            )

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rlgl.begin(render_type)
        var index = 0
        while index < triangle_count:
            let angle_offset = TWO_PI / float<-triangle_count
            let angle = angle_offset * float<-index
            let angle_offset_calculated = float<-(index + 1) * angle_offset
            let scale = rl.Vector2(x = point_scale, y = point_scale)

            let offset = rm.vector2_multiply(rl.Vector2(x = float<-math.sin(double<-angle), y = float<-(-math.cos(double<-angle))), scale)
            let offset2 = rm.vector2_multiply(rl.Vector2(x = float<-math.sin(double<-angle_offset_calculated), y = float<-(-math.cos(double<-angle_offset_calculated))), scale)
            let position = rm.vector2_add(center, offset)
            let position2 = rm.vector2_add(center, offset2)

            let angle_non_radian = (angle / TWO_PI) * 360.0
            let angle_non_radian_offset = (angle_offset / TWO_PI) * 360.0
            let current_color = rl.color_from_hsv(angle_non_radian, 1.0, 1.0)
            let offset_color = rl.color_from_hsv(angle_non_radian + angle_non_radian_offset, 1.0, 1.0)

            if render_type == rlgl.RL_TRIANGLES:
                rlgl.color4ub(current_color.r, current_color.g, current_color.b, current_color.a)
                rlgl.vertex2f(position.x, position.y)
                rlgl.color4f(value, value, value, 1.0)
                rlgl.vertex2f(center.x, center.y)
                rlgl.color4ub(offset_color.r, offset_color.g, offset_color.b, offset_color.a)
                rlgl.vertex2f(position2.x, position2.y)
            else:
                rlgl.color4ub(current_color.r, current_color.g, current_color.b, current_color.a)
                rlgl.vertex2f(position.x, position.y)
                rlgl.color4ub(rl.WHITE.r, rl.WHITE.g, rl.WHITE.b, rl.WHITE.a)
                rlgl.vertex2f(center.x, center.y)

                rlgl.vertex2f(center.x, center.y)
                rlgl.color4ub(offset_color.r, offset_color.g, offset_color.b, offset_color.a)
                rlgl.vertex2f(position2.x, position2.y)

                rlgl.vertex2f(position2.x, position2.y)
                rlgl.color4ub(current_color.r, current_color.g, current_color.b, current_color.a)
                rlgl.vertex2f(position.x, position.y)
            index += 1
        rlgl.end()

        var handle_color = rl.BLACK
        if rm.vector2_distance(center, circle_position) / point_scale <= 0.5 and value <= 0.5:
            handle_color = rl.DARKGRAY

        rl.draw_circle_lines_v(circle_position, 4.0, handle_color)
        rl.draw_rectangle_v(rl.Vector2(x = 8.0, y = 8.0), rl.Vector2(x = 64.0, y = 64.0), color)
        rl.draw_rectangle_lines_ex(rl.Rectangle(x = 8.0, y = 8.0, width = 64.0, height = 64.0), 2.0, rl.color_lerp(color, rl.BLACK, 0.5))
        rl.draw_text(text.cstr_as_str(rl.text_format("#%02X%02X%02X\n(%d, %d, %d)", color.r, color.g, color.b, color.r, color.g, color.b)), 8, 80, 20, rl.DARKGRAY)

        var copy_color = rl.DARKGRAY
        var copy_offset = 0
        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT_CONTROL) and rl.is_key_down(rl.KeyboardKey.KEY_C):
            copy_color = rl.DARKGREEN
            copy_offset = 4

        rl.draw_text("press ctrl+c to copy!", 8, 425 - copy_offset, 20, copy_color)
        rl.draw_text(text.cstr_as_str(rl.text_format("triangle count: %d", triangle_count)), 8, 395, 20, rl.DARKGRAY)
        gui.slider_bar(slider_rectangle, "value: ", "", value, 0.0, 1.0)
        rl.draw_fps(80, 8)
        rl.end_drawing()

    return 0
