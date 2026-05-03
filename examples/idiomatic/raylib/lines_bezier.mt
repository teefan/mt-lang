module examples.idiomatic.raylib.lines_bezier

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450


def main() -> i32:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(screen_width, screen_height, "Milk Tea Bezier Lines")
    defer rl.close_window()

    var start_point = rl.Vector2(x = 30.0, y = 30.0)
    var end_point = rl.Vector2(x = f32<-(screen_width - 30), y = f32<-(screen_height - 30))
    var moving_start = false
    var moving_end = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse = rl.get_mouse_position()
        let start_hovered = rl.check_collision_point_circle(mouse, start_point, 10.0)
        let end_hovered = rl.check_collision_point_circle(mouse, end_point, 10.0)

        if start_hovered and rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
            moving_start = true
        elif end_hovered and rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
            moving_end = true

        if moving_start:
            start_point = mouse
            if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
                moving_start = false

        if moving_end:
            end_point = mouse
            if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
                moving_end = false

        var start_radius: f32 = if start_hovered: 14.0 else: 8.0
        var end_radius: f32 = if end_hovered: 14.0 else: 8.0
        var start_color = if moving_start: rl.RED else: rl.BLUE
        var end_color = if moving_end: rl.RED else: rl.BLUE

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("MOVE START-END POINTS WITH MOUSE", 15, 20, 20, rl.GRAY)
        rl.draw_line_bezier(start_point, end_point, 4.0, rl.BLUE)
        rl.draw_circle_v(start_point, start_radius, start_color)
        rl.draw_circle_v(end_point, end_radius, end_color)

    return 0
