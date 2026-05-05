module examples.raylib.shapes.shapes_lines_drawing

import std.c.raylib as rl
import std.raylib.math as rm

const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [shapes] example - lines drawing"
const hint_text: cstr = c"try clicking and dragging!"


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var start_text = true
    var mouse_position_previous = rl.GetMousePosition()
    let canvas = rl.LoadRenderTexture(screen_width, screen_height)
    defer rl.UnloadRenderTexture(canvas)

    var line_thickness: float = 8.0
    var line_hue: float = 0.0

    rl.BeginTextureMode(canvas)
    rl.ClearBackground(rl.RAYWHITE)
    rl.EndTextureMode()

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT) and start_text:
            start_text = false

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_MIDDLE):
            rl.BeginTextureMode(canvas)
            rl.ClearBackground(rl.RAYWHITE)
            rl.EndTextureMode()

        let left_button_down = rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT)
        let right_button_down = rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_RIGHT)
        let mouse_position = rl.GetMousePosition()

        if left_button_down or right_button_down:
            var draw_color = rl.WHITE

            if left_button_down:
                line_hue += mouse_position_previous.distance(mouse_position) / 3.0
                while line_hue >= 360.0:
                    line_hue -= 360.0
                draw_color = rl.ColorFromHSV(line_hue, 1.0, 1.0)
            elif right_button_down:
                draw_color = rl.RAYWHITE

            rl.BeginTextureMode(canvas)
            rl.DrawCircleV(mouse_position_previous, line_thickness / 2.0, draw_color)
            rl.DrawCircleV(mouse_position, line_thickness / 2.0, draw_color)
            rl.DrawLineEx(mouse_position_previous, mouse_position, line_thickness, draw_color)
            rl.EndTextureMode()

        line_thickness += rl.GetMouseWheelMove()
        line_thickness = rm.clamp(line_thickness, 1.0, 500.0)
        mouse_position_previous = mouse_position

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.DrawTextureRec(
            canvas.texture,
            rl.Rectangle(
                x = 0.0,
                y = 0.0,
                width = canvas.texture.width,
                height = -canvas.texture.height,
            ),
            rm.Vector2.zero(),
            rl.WHITE,
        )

        if not left_button_down:
            rl.DrawCircleLinesV(mouse_position, line_thickness / 2.0, rl.Color(r = 127, g = 127, b = 127, a = 127))

        if start_text:
            rl.DrawText(hint_text, 275, 215, 20, rl.LIGHTGRAY)

    return 0
