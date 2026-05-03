module examples.raylib.shapes.shapes_lines_bezier

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - lines bezier"
const help_text: cstr = c"MOVE START-END POINTS WITH MOUSE"


def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var start_point = rl.Vector2(x = 30.0, y = 30.0)
    var end_point = rl.Vector2(x = f32<-(screen_width - 30), y = f32<-(screen_height - 30))
    var move_start_point = false
    var move_end_point = false

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let mouse = rl.GetMousePosition()
        let start_hovered = rl.CheckCollisionPointCircle(mouse, start_point, 10.0)
        let end_hovered = rl.CheckCollisionPointCircle(mouse, end_point, 10.0)

        if start_hovered and rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT):
            move_start_point = true
        elif end_hovered and rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT):
            move_end_point = true

        if move_start_point:
            start_point = mouse
            if rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT):
                move_start_point = false

        if move_end_point:
            end_point = mouse
            if rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT):
                move_end_point = false

        var start_radius: f32 = 8.0
        var end_radius: f32 = 8.0
        var start_color = rl.BLUE
        var end_color = rl.BLUE

        if start_hovered:
            start_radius = 14.0
        if end_hovered:
            end_radius = 14.0
        if move_start_point:
            start_color = rl.RED
        if move_end_point:
            end_color = rl.RED

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawText(help_text, 15, 20, 20, rl.GRAY)
        rl.DrawLineBezier(start_point, end_point, 4.0, rl.BLUE)
        rl.DrawCircleV(start_point, start_radius, start_color)
        rl.DrawCircleV(end_point, end_radius, end_color)

    return 0
