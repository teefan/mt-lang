module examples.raylib.shapes.shapes_rlgl_color_wheel

import std.c.libm as math
import std.c.raygui as gui
import std.c.raylib as rl
import std.c.rlgl as rlgl
import std.raylib.math as mt_math

const screen_width: i32 = 800
const screen_height: i32 = 450
const points_min: i32 = 3
const points_max: i32 = 256
const window_title: cstr = c"raylib [shapes] example - rlgl color wheel"
const copy_hex_format: cstr = c"#%02X%02X%02X"
const color_text_format: cstr = c"#%02X%02X%02X\n(%d, %d, %d)"
const triangle_count_format: cstr = c"triangle count: %d"
const copy_text: cstr = c"press ctrl+c to copy!"
const slider_left_text: cstr = c"value: "
const slider_right_text: cstr = c""


def angle_fraction(center: rl.Vector2, circle_position: rl.Vector2, point_scale: f32) -> f32:
    let reference = rl.Vector2(x = 0.0, y = -point_scale)
    let relative = center.subtract(circle_position)
    return (reference.angle(relative) / rl.PI + 1.0) / 2.0


def clamp_handle_position(center: rl.Vector2, circle_position: rl.Vector2, point_scale: f32) -> rl.Vector2:
    let distance = center.distance(circle_position) / point_scale
    if distance <= 1.0:
        return circle_position

    let angle = angle_fraction(center, circle_position, point_scale)
    return rl.Vector2(
        x = math.sinf(angle * (rl.PI * 2.0)) * point_scale,
        y = -math.cosf(angle * (rl.PI * 2.0)) * point_scale,
    ).add(center)


def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var triangle_count: i32 = 64
    var point_scale: f32 = 150.0
    var value: f32 = 1.0

    let center = rl.Vector2(x = screen_width / 2.0, y = screen_height / 2.0)
    var circle_position = center
    var color = rl.Color(r = 255, g = 255, b = 255, a = 255)
    var slider_clicked = false
    var setting_color = false
    var render_type: i32 = rlgl.RL_TRIANGLES

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        triangle_count += i32<-rl.GetMouseWheelMove()
        if triangle_count < points_min:
            triangle_count = points_min
        if triangle_count > points_max:
            triangle_count = points_max

        let slider_rectangle = gui.Rectangle(x = 42.0, y = 125.0, width = 64.0, height = 16.0)
        let mouse_position = rl.GetMousePosition()
        let slider_hover = mouse_position.x >= slider_rectangle.x and mouse_position.y >= slider_rectangle.y and mouse_position.x < slider_rectangle.x + slider_rectangle.width and mouse_position.y < slider_rectangle.y + slider_rectangle.height

        if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT_CONTROL) and rl.IsKeyDown(rl.KeyboardKey.KEY_C):
            if rl.IsKeyPressed(rl.KeyboardKey.KEY_C):
                rl.SetClipboardText(rl.TextFormat(copy_hex_format, color.r, color.g, color.b))

        if rl.IsKeyDown(rl.KeyboardKey.KEY_UP):
            point_scale *= f32<-1.025
            if point_scale > f32<-screen_height / f32<-2:
                point_scale = f32<-screen_height / f32<-2
            else:
                circle_position = circle_position.subtract(center).multiply(rl.Vector2(x = 1.025, y = 1.025)).add(center)

        if rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN):
            point_scale *= f32<-0.975
            if point_scale < f32<-32.0:
                point_scale = f32<-32.0
            else:
                circle_position = circle_position.subtract(center).multiply(rl.Vector2(x = 0.975, y = 0.975)).add(center)
                circle_position = clamp_handle_position(center, circle_position, point_scale)

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT) and center.distance(mouse_position) <= point_scale + 10.0:
            setting_color = true

        if rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT):
            setting_color = false

        if slider_hover and rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            slider_clicked = true

        if slider_clicked and rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT):
            slider_clicked = false

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            render_type = rlgl.RL_LINES

        if rl.IsKeyReleased(rl.KeyboardKey.KEY_SPACE):
            render_type = rlgl.RL_TRIANGLES

        if setting_color or slider_clicked:
            if setting_color:
                circle_position = mouse_position

            let distance = center.distance(circle_position) / point_scale
            let angle = angle_fraction(center, circle_position, point_scale)
            if setting_color and distance > 1.0:
                circle_position = clamp_handle_position(center, circle_position, point_scale)

            let angle_360 = angle * 360.0
            let saturation = mt_math.clamp(distance, 0.0, 1.0)
            let value_actual = mt_math.clamp(distance, 0.0, 1.0)
            color = rl.ColorLerp(
                rl.Color(r = i32<-(value * 255.0), g = i32<-(value * 255.0), b = i32<-(value * 255.0), a = 255),
                rl.ColorFromHSV(angle_360, saturation, 1.0),
                value_actual,
            )

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rlgl.rlBegin(render_type)
        for index in 0..triangle_count:
            let angle_offset = (rl.PI * 2.0) / f32<-triangle_count
            let angle = angle_offset * f32<-index
            let angle_offset_calculated = (f32<-index + 1.0) * angle_offset
            let scale = rl.Vector2(x = point_scale, y = point_scale)

            let offset = rl.Vector2(x = math.sinf(angle), y = -math.cosf(angle)).multiply(scale)
            let offset2 = rl.Vector2(x = math.sinf(angle_offset_calculated), y = -math.cosf(angle_offset_calculated)).multiply(scale)
            let position = center.add(offset)
            let position2 = center.add(offset2)

            let angle_non_radian = angle / (2.0 * rl.PI) * 360.0
            let angle_non_radian_offset = angle_offset / (2.0 * rl.PI) * 360.0
            let current_color = rl.ColorFromHSV(angle_non_radian, 1.0, 1.0)
            let offset_color = rl.ColorFromHSV(angle_non_radian + angle_non_radian_offset, 1.0, 1.0)

            if render_type == rlgl.RL_TRIANGLES:
                rlgl.rlColor4ub(current_color.r, current_color.g, current_color.b, current_color.a)
                rlgl.rlVertex2f(position.x, position.y)
                rlgl.rlColor4f(value, value, value, 1.0)
                rlgl.rlVertex2f(center.x, center.y)
                rlgl.rlColor4ub(offset_color.r, offset_color.g, offset_color.b, offset_color.a)
                rlgl.rlVertex2f(position2.x, position2.y)
            elif render_type == rlgl.RL_LINES:
                rlgl.rlColor4ub(current_color.r, current_color.g, current_color.b, current_color.a)
                rlgl.rlVertex2f(position.x, position.y)
                rlgl.rlColor4ub(rl.WHITE.r, rl.WHITE.g, rl.WHITE.b, rl.WHITE.a)
                rlgl.rlVertex2f(center.x, center.y)

                rlgl.rlVertex2f(center.x, center.y)
                rlgl.rlColor4ub(offset_color.r, offset_color.g, offset_color.b, offset_color.a)
                rlgl.rlVertex2f(position2.x, position2.y)

                rlgl.rlVertex2f(position2.x, position2.y)
                rlgl.rlColor4ub(current_color.r, current_color.g, current_color.b, current_color.a)
                rlgl.rlVertex2f(position.x, position.y)
        rlgl.rlEnd()

        var handle_color = rl.BLACK
        if center.distance(circle_position) / point_scale <= 0.5 and value <= 0.5:
            handle_color = rl.DARKGRAY

        rl.DrawCircleLinesV(circle_position, 4.0, handle_color)
        rl.DrawRectangleV(rl.Vector2(x = 8.0, y = 8.0), rl.Vector2(x = 64.0, y = 64.0), color)
        rl.DrawRectangleLinesEx(rl.Rectangle(x = 8.0, y = 8.0, width = 64.0, height = 64.0), 2.0, rl.ColorLerp(color, rl.BLACK, 0.5))

        rl.DrawText(rl.TextFormat(color_text_format, color.r, color.g, color.b, color.r, color.g, color.b), 8, 80, 20, rl.DARKGRAY)

        var copy_color = rl.DARKGRAY
        var copy_offset = 0
        if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT_CONTROL) and rl.IsKeyDown(rl.KeyboardKey.KEY_C):
            copy_color = rl.DARKGREEN
            copy_offset = 4

        rl.DrawText(copy_text, 8, 425 - copy_offset, 20, copy_color)
        rl.DrawText(rl.TextFormat(triangle_count_format, triangle_count), 8, 395, 20, rl.DARKGRAY)

        gui.GuiSliderBar(slider_rectangle, slider_left_text, slider_right_text, ptr_of(ref_of(value)), 0.0, 1.0)
        rl.DrawFPS(80, 8)

    return 0
