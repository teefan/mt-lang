module examples.raylib.shapes.shapes_colors_palette

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const max_colors_count: i32 = 21
const grid_columns: i32 = 7
const window_title: cstr = c"raylib [shapes] example - colors palette"
const title_text: cstr = c"raylib colors palette"
const help_text: cstr = c"press SPACE to see all colors"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var colors = zero[array[rl.Color, 21]]()
    colors[0] = rl.DARKGRAY
    colors[1] = rl.MAROON
    colors[2] = rl.ORANGE
    colors[3] = rl.DARKGREEN
    colors[4] = rl.DARKBLUE
    colors[5] = rl.DARKPURPLE
    colors[6] = rl.DARKBROWN
    colors[7] = rl.GRAY
    colors[8] = rl.RED
    colors[9] = rl.GOLD
    colors[10] = rl.LIME
    colors[11] = rl.BLUE
    colors[12] = rl.VIOLET
    colors[13] = rl.BROWN
    colors[14] = rl.LIGHTGRAY
    colors[15] = rl.PINK
    colors[16] = rl.YELLOW
    colors[17] = rl.GREEN
    colors[18] = rl.SKYBLUE
    colors[19] = rl.PURPLE
    colors[20] = rl.BEIGE

    var color_names = zero[array[cstr, 21]]()
    color_names[0] = c"DARKGRAY"
    color_names[1] = c"MAROON"
    color_names[2] = c"ORANGE"
    color_names[3] = c"DARKGREEN"
    color_names[4] = c"DARKBLUE"
    color_names[5] = c"DARKPURPLE"
    color_names[6] = c"DARKBROWN"
    color_names[7] = c"GRAY"
    color_names[8] = c"RED"
    color_names[9] = c"GOLD"
    color_names[10] = c"LIME"
    color_names[11] = c"BLUE"
    color_names[12] = c"VIOLET"
    color_names[13] = c"BROWN"
    color_names[14] = c"LIGHTGRAY"
    color_names[15] = c"PINK"
    color_names[16] = c"YELLOW"
    color_names[17] = c"GREEN"
    color_names[18] = c"SKYBLUE"
    color_names[19] = c"PURPLE"
    color_names[20] = c"BEIGE"

    var color_rects = zero[array[rl.Rectangle, 21]]()
    var color_state = zero[array[i32, 21]]()

    for index in range(0, max_colors_count):
        let column = index % grid_columns
        let row = index / grid_columns
        let column_f: f32 = column
        let row_f: f32 = row

        color_rects[index] = rl.Rectangle(
            x = 20.0 + 110.0 * column_f,
            y = 80.0 + 110.0 * row_f,
            width = 100.0,
            height = 100.0,
        )

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let mouse_point = rl.GetMousePosition()

        for index in range(0, max_colors_count):
            if rl.CheckCollisionPointRec(mouse_point, color_rects[index]):
                color_state[index] = 1
            else:
                color_state[index] = 0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawText(title_text, 28, 42, 20, rl.BLACK)
        rl.DrawText(help_text, rl.GetScreenWidth() - 180, rl.GetScreenHeight() - 40, 10, rl.GRAY)

        for index in range(0, max_colors_count):
            rl.DrawRectangleRec(color_rects[index], rl.Fade(colors[index], if color_state[index] != 0 then 0.6 else 1.0))

            if rl.IsKeyDown(rl.KeyboardKey.KEY_SPACE) or color_state[index] != 0:
                rl.DrawRectangle(
                    cast[i32](color_rects[index].x),
                    cast[i32](color_rects[index].y + color_rects[index].height - 26.0),
                    cast[i32](color_rects[index].width),
                    20,
                    rl.BLACK,
                )
                rl.DrawRectangleLinesEx(color_rects[index], 6.0, rl.Fade(rl.BLACK, 0.3))
                rl.DrawText(
                    color_names[index],
                    cast[i32](color_rects[index].x + color_rects[index].width - cast[f32](rl.MeasureText(color_names[index], 10)) - 12.0),
                    cast[i32](color_rects[index].y + color_rects[index].height - 20.0),
                    10,
                    colors[index],
                )

    return 0
