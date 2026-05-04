module examples.raylib.shapes.shapes_rlgl_triangle

import std.c.raylib as rl
import std.c.rlgl as rlgl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - rlgl triangle"
const lines_mode_text: cstr = c"SPACE: Toggle lines mode"
const culling_text: cstr = c"LEFT-RIGHT: Toggle backface culling"
const mouse_text: cstr = c"MOUSE: Click and drag vertex points"
const reset_text: cstr = c"R: Reset triangle to start positions"


def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let starting_positions = array[rl.Vector2, 3](
        rl.Vector2(x = 400.0, y = 150.0),
        rl.Vector2(x = 300.0, y = 300.0),
        rl.Vector2(x = 500.0, y = 300.0),
    )
    var triangle_positions = array[rl.Vector2, 3](
        starting_positions[0],
        starting_positions[1],
        starting_positions[2],
    )

    var triangle_index = -1
    var lines_mode = false
    let handle_radius: f32 = 8.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            lines_mode = not lines_mode

        let mouse_position = rl.GetMousePosition()
        for index in 0..3:
            if rl.CheckCollisionPointCircle(mouse_position, triangle_positions[index], handle_radius) and rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT):
                triangle_index = index
                break

        if triangle_index != -1:
            let mouse_delta = rl.GetMouseDelta()
            triangle_positions[triangle_index].x += mouse_delta.x
            triangle_positions[triangle_index].y += mouse_delta.y

        if rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT):
            triangle_index = -1

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
            rlgl.rlEnableBackfaceCulling()
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            rlgl.rlDisableBackfaceCulling()

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_R):
            triangle_positions[0] = starting_positions[0]
            triangle_positions[1] = starting_positions[1]
            triangle_positions[2] = starting_positions[2]
            rlgl.rlEnableBackfaceCulling()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        if lines_mode:
            rlgl.rlBegin(rlgl.RL_LINES)
            rlgl.rlColor4ub(255, 0, 0, 255)
            rlgl.rlVertex2f(triangle_positions[0].x, triangle_positions[0].y)
            rlgl.rlColor4ub(0, 255, 0, 255)
            rlgl.rlVertex2f(triangle_positions[1].x, triangle_positions[1].y)

            rlgl.rlColor4ub(0, 255, 0, 255)
            rlgl.rlVertex2f(triangle_positions[1].x, triangle_positions[1].y)
            rlgl.rlColor4ub(0, 0, 255, 255)
            rlgl.rlVertex2f(triangle_positions[2].x, triangle_positions[2].y)

            rlgl.rlColor4ub(0, 0, 255, 255)
            rlgl.rlVertex2f(triangle_positions[2].x, triangle_positions[2].y)
            rlgl.rlColor4ub(255, 0, 0, 255)
            rlgl.rlVertex2f(triangle_positions[0].x, triangle_positions[0].y)
            rlgl.rlEnd()
        else:
            rlgl.rlBegin(rlgl.RL_TRIANGLES)
            rlgl.rlColor4ub(255, 0, 0, 255)
            rlgl.rlVertex2f(triangle_positions[0].x, triangle_positions[0].y)
            rlgl.rlColor4ub(0, 255, 0, 255)
            rlgl.rlVertex2f(triangle_positions[1].x, triangle_positions[1].y)
            rlgl.rlColor4ub(0, 0, 255, 255)
            rlgl.rlVertex2f(triangle_positions[2].x, triangle_positions[2].y)
            rlgl.rlEnd()

        for index in 0..3:
            if rl.CheckCollisionPointCircle(mouse_position, triangle_positions[index], handle_radius):
                rl.DrawCircleV(triangle_positions[index], handle_radius, rl.Fade(rl.DARKGRAY, 0.5))

            if index == triangle_index:
                rl.DrawCircleV(triangle_positions[index], handle_radius, rl.DARKGRAY)

            rl.DrawCircleLinesV(triangle_positions[index], handle_radius, rl.BLACK)

        rl.DrawText(lines_mode_text, 10, 10, 20, rl.DARKGRAY)
        rl.DrawText(culling_text, 10, 40, 20, rl.DARKGRAY)
        rl.DrawText(mouse_text, 10, 70, 20, rl.DARKGRAY)
        rl.DrawText(reset_text, 10, 100, 20, rl.DARKGRAY)

    return 0
