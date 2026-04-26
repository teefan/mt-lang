module examples.raylib.shapes.shapes_dashed_line

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const line_color_count: i32 = 8
const window_title: cstr = c"raylib [shapes] example - dashed line"
const controls_text: cstr = c"CONTROLS:"
const dash_help_text: cstr = c"UP/DOWN: Change Dash Length"
const space_help_text: cstr = c"LEFT/RIGHT: Change Space Length"
const color_help_text: cstr = c"C: Cycle Color"
const status_format: cstr = c"Dash: %.0f | Space: %.0f"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let line_start_position = rl.Vector2(x = 20.0, y = 50.0)
    var line_end_position = rl.Vector2(x = 780.0, y = 400.0)
    var dash_length: f32 = 25.0
    var blank_length: f32 = 15.0

    var line_colors = zero[array[rl.Color, 8]]()
    line_colors[0] = rl.RED
    line_colors[1] = rl.ORANGE
    line_colors[2] = rl.GOLD
    line_colors[3] = rl.GREEN
    line_colors[4] = rl.BLUE
    line_colors[5] = rl.VIOLET
    line_colors[6] = rl.PINK
    line_colors[7] = rl.BLACK
    var color_index = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        line_end_position = rl.GetMousePosition()

        if rl.IsKeyDown(rl.KeyboardKey.KEY_UP):
            dash_length += 1.0
        if rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN) and dash_length > 1.0:
            dash_length -= 1.0

        if rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT):
            blank_length += 1.0
        if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT) and blank_length > 1.0:
            blank_length -= 1.0

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_C):
            color_index = (color_index + 1) % line_color_count

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawLineDashed(line_start_position, line_end_position, cast[i32](dash_length), cast[i32](blank_length), line_colors[color_index])

        rl.DrawRectangle(5, 5, 265, 95, rl.Fade(rl.SKYBLUE, 0.5))
        rl.DrawRectangleLines(5, 5, 265, 95, rl.BLUE)
        rl.DrawText(controls_text, 15, 15, 10, rl.BLACK)
        rl.DrawText(dash_help_text, 15, 35, 10, rl.BLACK)
        rl.DrawText(space_help_text, 15, 55, 10, rl.BLACK)
        rl.DrawText(color_help_text, 15, 75, 10, rl.BLACK)
        rl.DrawText(rl.TextFormat(status_format, dash_length, blank_length), 15, 115, 10, rl.DARKGRAY)
        rl.DrawFPS(screen_width - 80, 10)

    return 0
