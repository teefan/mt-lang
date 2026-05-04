module examples.idiomatic.raylib.rlgl_triangle

import std.raylib as rl
import std.rlgl as rlgl

const screen_width: i32 = 800
const screen_height: i32 = 450


def emit_triangle_edge(start: rl.Vector2, finish: rl.Vector2, start_color: rl.Color, finish_color: rl.Color) -> void:
    rlgl.color_4ub(start_color.r, start_color.g, start_color.b, start_color.a)
    rlgl.vertex_2f(start.x, start.y)
    rlgl.color_4ub(finish_color.r, finish_color.g, finish_color.b, finish_color.a)
    rlgl.vertex_2f(finish.x, finish.y)


def emit_triangle_point(point: rl.Vector2, color: rl.Color) -> void:
    rlgl.color_4ub(color.r, color.g, color.b, color.a)
    rlgl.vertex_2f(point.x, point.y)


def main() -> i32:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(screen_width, screen_height, "Milk Tea rlgl Triangle")
    defer rl.close_window()

    let starting_positions = array[rl.Vector2, 3](
        rl.Vector2(x = 400.0, y = 150.0),
        rl.Vector2(x = 300.0, y = 300.0),
        rl.Vector2(x = 500.0, y = 300.0),
    )
    var triangle_positions = array[rl.Vector2, 3](starting_positions[0], starting_positions[1], starting_positions[2])

    var triangle_index = -1
    var lines_mode = false
    let handle_radius: f32 = 8.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            lines_mode = not lines_mode

        let mouse_position = rl.get_mouse_position()
        for index in 0..3:
            if rl.check_collision_point_circle(mouse_position, triangle_positions[index], handle_radius) and rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
                triangle_index = index
                break

        if triangle_index != -1:
            let mouse_delta = rl.get_mouse_delta()
            triangle_positions[triangle_index].x += mouse_delta.x
            triangle_positions[triangle_index].y += mouse_delta.y

        if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
            triangle_index = -1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            rlgl.enable_backface_culling()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            rlgl.disable_backface_culling()

        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            triangle_positions[0] = starting_positions[0]
            triangle_positions[1] = starting_positions[1]
            triangle_positions[2] = starting_positions[2]
            rlgl.enable_backface_culling()

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        if lines_mode:
            rlgl.begin(rlgl.RL_LINES)
            emit_triangle_edge(triangle_positions[0], triangle_positions[1], rl.RED, rl.GREEN)
            emit_triangle_edge(triangle_positions[1], triangle_positions[2], rl.GREEN, rl.BLUE)
            emit_triangle_edge(triangle_positions[2], triangle_positions[0], rl.BLUE, rl.RED)
            rlgl.end()
        else:
            rlgl.begin(rlgl.RL_TRIANGLES)
            emit_triangle_point(triangle_positions[0], rl.RED)
            emit_triangle_point(triangle_positions[1], rl.GREEN)
            emit_triangle_point(triangle_positions[2], rl.BLUE)
            rlgl.end()

        for index in 0..3:
            if rl.check_collision_point_circle(mouse_position, triangle_positions[index], handle_radius):
                rl.draw_circle_v(triangle_positions[index], handle_radius, rl.fade(rl.DARKGRAY, 0.5))

            if index == triangle_index:
                rl.draw_circle_v(triangle_positions[index], handle_radius, rl.DARKGRAY)

            rl.draw_circle_lines_v(triangle_positions[index], handle_radius, rl.BLACK)

        rl.draw_text("SPACE: Toggle lines mode", 10, 10, 20, rl.DARKGRAY)
        rl.draw_text("LEFT-RIGHT: Toggle backface culling", 10, 40, 20, rl.DARKGRAY)
        rl.draw_text("MOUSE: Click and drag vertex points", 10, 70, 20, rl.DARKGRAY)
        rl.draw_text("R: Reset triangle to start positions", 10, 100, 20, rl.DARKGRAY)

    return 0
