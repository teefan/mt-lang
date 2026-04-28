module examples.idiomatic.raylib.colors_palette

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const color_count: i32 = 21
const grid_columns: i32 = 7

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Colors Palette")
    defer rl.close_window()

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

    var color_names = zero[array[str, 21]]()
    color_names[0] = "DARKGRAY"
    color_names[1] = "MAROON"
    color_names[2] = "ORANGE"
    color_names[3] = "DARKGREEN"
    color_names[4] = "DARKBLUE"
    color_names[5] = "DARKPURPLE"
    color_names[6] = "DARKBROWN"
    color_names[7] = "GRAY"
    color_names[8] = "RED"
    color_names[9] = "GOLD"
    color_names[10] = "LIME"
    color_names[11] = "BLUE"
    color_names[12] = "VIOLET"
    color_names[13] = "BROWN"
    color_names[14] = "LIGHTGRAY"
    color_names[15] = "PINK"
    color_names[16] = "YELLOW"
    color_names[17] = "GREEN"
    color_names[18] = "SKYBLUE"
    color_names[19] = "PURPLE"
    color_names[20] = "BEIGE"

    var rectangles = zero[array[rl.Rectangle, 21]]()
    var hovered = zero[array[bool, 21]]()

    for index in range(0, color_count):
        let column = index % grid_columns
        let row = index / grid_columns
        rectangles[index] = rl.Rectangle(
            x = 20.0 + 110.0 * cast[f32](column),
            y = 80.0 + 110.0 * cast[f32](row),
            width = 100.0,
            height = 100.0,
        )

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse_position = rl.get_mouse_position()

        for index in range(0, color_count):
            hovered[index] = rl.check_collision_point_rec(mouse_position, rectangles[index])

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("raylib colors palette", 28, 42, 20, rl.BLACK)
        rl.draw_text("press SPACE to see all colors", rl.get_screen_width() - 180, rl.get_screen_height() - 40, 10, rl.GRAY)

        for index in range(0, color_count):
            let rectangle = rectangles[index]
            rl.draw_rectangle_rec(rectangle, rl.fade(colors[index], if hovered[index] then 0.6 else 1.0))

            if rl.is_key_down(rl.KeyboardKey.KEY_SPACE) or hovered[index]:
                rl.draw_rectangle(
                    cast[i32](rectangle.x),
                    cast[i32](rectangle.y + rectangle.height - 26.0),
                    cast[i32](rectangle.width),
                    20,
                    rl.BLACK,
                )
                rl.draw_rectangle_lines_ex(rectangle, 6.0, rl.fade(rl.BLACK, 0.3))
                let label = color_names[index]
                rl.draw_text(
                    label,
                    cast[i32](rectangle.x + rectangle.width - cast[f32](rl.measure_text(label, 10)) - 12.0),
                    cast[i32](rectangle.y + rectangle.height - 20.0),
                    10,
                    colors[index],
                )

    return 0
