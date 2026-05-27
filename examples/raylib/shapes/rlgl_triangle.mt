import std.raylib as rl
import std.rlgl as rlgl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - rlgl triangle")
    defer rl.close_window()

    let starting_positions = array[rl.Vector2, 3](
        rl.Vector2(x = 400.0, y = 150.0),
        rl.Vector2(x = 300.0, y = 300.0),
        rl.Vector2(x = 500.0, y = 300.0),
    )
    var triangle_positions = array[rl.Vector2, 3](starting_positions[0], starting_positions[1], starting_positions[2])

    var triangle_index = -1
    var lines_mode = false
    var handle_radius: float = 8.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            lines_mode = not lines_mode

        var index = 0
        while index < 3:
            if rl.check_collision_point_circle(rl.get_mouse_position(), triangle_positions[index], handle_radius) and rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
                triangle_index = index
                break
            index += 1

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
        rl.clear_background(rl.RAYWHITE)

        if lines_mode:
            rlgl.begin(rlgl.RL_LINES)
            rlgl.color4ub(255, 0, 0, 255)
            rlgl.vertex2f(triangle_positions[0].x, triangle_positions[0].y)
            rlgl.color4ub(0, 255, 0, 255)
            rlgl.vertex2f(triangle_positions[1].x, triangle_positions[1].y)

            rlgl.color4ub(0, 255, 0, 255)
            rlgl.vertex2f(triangle_positions[1].x, triangle_positions[1].y)
            rlgl.color4ub(0, 0, 255, 255)
            rlgl.vertex2f(triangle_positions[2].x, triangle_positions[2].y)

            rlgl.color4ub(0, 0, 255, 255)
            rlgl.vertex2f(triangle_positions[2].x, triangle_positions[2].y)
            rlgl.color4ub(255, 0, 0, 255)
            rlgl.vertex2f(triangle_positions[0].x, triangle_positions[0].y)
            rlgl.end()
        else:
            rlgl.begin(rlgl.RL_TRIANGLES)
            rlgl.color4ub(255, 0, 0, 255)
            rlgl.vertex2f(triangle_positions[0].x, triangle_positions[0].y)
            rlgl.color4ub(0, 255, 0, 255)
            rlgl.vertex2f(triangle_positions[1].x, triangle_positions[1].y)
            rlgl.color4ub(0, 0, 255, 255)
            rlgl.vertex2f(triangle_positions[2].x, triangle_positions[2].y)
            rlgl.end()

        index = 0
        while index < 3:
            if rl.check_collision_point_circle(rl.get_mouse_position(), triangle_positions[index], handle_radius):
                rl.draw_circle_v(triangle_positions[index], handle_radius, rl.color_alpha(rl.DARKGRAY, 0.5))
            if index == triangle_index:
                rl.draw_circle_v(triangle_positions[index], handle_radius, rl.DARKGRAY)
            rl.draw_circle_lines_v(triangle_positions[index], handle_radius, rl.BLACK)
            index += 1

        rl.draw_text("SPACE: Toggle lines mode", 10, 10, 20, rl.DARKGRAY)
        rl.draw_text("LEFT-RIGHT: Toggle backface culling", 10, 40, 20, rl.DARKGRAY)
        rl.draw_text("MOUSE: Click and drag vertex points", 10, 70, 20, rl.DARKGRAY)
        rl.draw_text("R: Reset triangle to start positions", 10, 100, 20, rl.DARKGRAY)
        rl.end_drawing()

    return 0
