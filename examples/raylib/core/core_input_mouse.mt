module examples.raylib.core.core_input_mouse

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - input mouse"
const movement_text: cstr = c"move ball with mouse and click mouse button to change color"
const cursor_text: cstr = c"Press 'H' to toggle cursor visibility"
const hidden_text: cstr = c"CURSOR HIDDEN"
const visible_text: cstr = c"CURSOR VISIBLE"
const ball_radius: f32 = 40.0


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var ball_position = rl.Vector2(x = -100.0, y = -100.0)
    var ball_color = rl.DARKBLUE

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_H):
            if rl.IsCursorHidden():
                rl.ShowCursor()
            else:
                rl.HideCursor()

        ball_position = rl.GetMousePosition()

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            ball_color = rl.MAROON
        elif rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_MIDDLE):
            ball_color = rl.LIME
        elif rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            ball_color = rl.DARKBLUE
        elif rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_SIDE):
            ball_color = rl.PURPLE
        elif rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_EXTRA):
            ball_color = rl.YELLOW
        elif rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_FORWARD):
            ball_color = rl.ORANGE
        elif rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_BACK):
            ball_color = rl.BEIGE

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawCircleV(ball_position, ball_radius, ball_color)
        rl.DrawText(movement_text, 10, 10, 20, rl.DARKGRAY)
        rl.DrawText(cursor_text, 10, 30, 20, rl.DARKGRAY)

        if rl.IsCursorHidden():
            rl.DrawText(hidden_text, 20, 60, 20, rl.RED)
        else:
            rl.DrawText(visible_text, 20, 60, 20, rl.LIME)

    return 0
