import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const HANDLE_RADIUS: float = 10.0
const ACTIVE_RADIUS: float = 14.0
const IDLE_RADIUS: float = 8.0


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - lines bezier")
    defer rl.close_window()

    var start_point = rl.Vector2(x = 30.0, y = 30.0)
    var end_point = rl.Vector2(x = float<-SCREEN_WIDTH - 30.0, y = float<-SCREEN_HEIGHT - 30.0)
    var move_start_point = false
    var move_end_point = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse = rl.get_mouse_position()

        if rl.check_collision_point_circle(
            mouse,
            start_point,
            HANDLE_RADIUS
        ) and rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
            move_start_point = true
        else if rl.check_collision_point_circle(
            mouse,
            end_point,
            HANDLE_RADIUS
        ) and rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
            move_end_point = true

        if move_start_point:
            start_point = mouse
            if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
                move_start_point = false

        if move_end_point:
            end_point = mouse
            if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
                move_end_point = false

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text("MOVE START-END POINTS WITH MOUSE", 15, 20, 20, rl.GRAY)
        rl.draw_line_bezier(start_point, end_point, 4.0, rl.BLUE)

        let start_radius = if rl.check_collision_point_circle(
            mouse,
            start_point,
            HANDLE_RADIUS
        ): ACTIVE_RADIUS else: IDLE_RADIUS
        let start_color = if move_start_point: rl.RED else: rl.BLUE
        rl.draw_circle_v(start_point, start_radius, start_color)

        let end_radius = if rl.check_collision_point_circle(
            mouse,
            end_point,
            HANDLE_RADIUS
        ): ACTIVE_RADIUS else: IDLE_RADIUS
        let end_color = if move_end_point: rl.RED else: rl.BLUE
        rl.draw_circle_v(end_point, end_radius, end_color)

        rl.end_drawing()

    return 0
