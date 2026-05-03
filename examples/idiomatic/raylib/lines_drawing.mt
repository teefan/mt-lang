module examples.idiomatic.raylib.lines_drawing

import std.raylib as rl
import std.raylib.math as math

const screen_width: i32 = 800
const screen_height: i32 = 450


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Lines Drawing")
    defer rl.close_window()

    var show_hint = true
    var previous_mouse_position = rl.get_mouse_position()
    let canvas = rl.load_render_texture(screen_width, screen_height)
    defer rl.unload_render_texture(canvas)

    var line_thickness: f32 = 8.0
    var line_hue: f32 = 0.0

    rl.begin_texture_mode(canvas)
    rl.clear_background(rl.RAYWHITE)
    rl.end_texture_mode()

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT) and show_hint:
            show_hint = false

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_MIDDLE):
            rl.begin_texture_mode(canvas)
            rl.clear_background(rl.RAYWHITE)
            rl.end_texture_mode()

        let left_button_down = rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT)
        let right_button_down = rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_RIGHT)
        let mouse_position = rl.get_mouse_position()

        if left_button_down or right_button_down:
            var draw_color = rl.RAYWHITE

            if left_button_down:
                line_hue += previous_mouse_position.distance(mouse_position) / 3.0
                while line_hue >= 360.0:
                    line_hue -= 360.0
                draw_color = rl.color_from_hsv(line_hue, 1.0, 1.0)

            rl.begin_texture_mode(canvas)
            rl.draw_circle_v(previous_mouse_position, line_thickness / 2.0, draw_color)
            rl.draw_circle_v(mouse_position, line_thickness / 2.0, draw_color)
            rl.draw_line_ex(previous_mouse_position, mouse_position, line_thickness, draw_color)
            rl.end_texture_mode()

        line_thickness += rl.get_mouse_wheel_move()
        line_thickness = math.clamp(line_thickness, 1.0, 500.0)
        previous_mouse_position = mouse_position

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.draw_texture_rec(
            canvas.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = canvas.texture.width, height = -canvas.texture.height),
            math.Vector2.zero(),
            rl.WHITE,
        )

        if not left_button_down:
            rl.draw_circle_lines_v(mouse_position, line_thickness / 2.0, rl.Color(r = 127, g = 127, b = 127, a = 127))

        if show_hint:
            rl.draw_text("try clicking and dragging!", 275, 215, 20, rl.LIGHTGRAY)

    return 0
