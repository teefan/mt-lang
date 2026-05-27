import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_COLORS_COUNT: int = 21


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - colors palette")
    defer rl.close_window()

    let colors = array[rl.Color, MAX_COLORS_COUNT](
        rl.DARKGRAY, rl.MAROON, rl.ORANGE, rl.DARKGREEN, rl.DARKBLUE, rl.DARKPURPLE, rl.DARKBROWN,
        rl.GRAY, rl.RED, rl.GOLD, rl.LIME, rl.BLUE, rl.VIOLET, rl.BROWN, rl.LIGHTGRAY, rl.PINK, rl.YELLOW,
        rl.GREEN, rl.SKYBLUE, rl.PURPLE, rl.BEIGE,
    )
    let color_names = array[str, MAX_COLORS_COUNT](
        "DARKGRAY", "MAROON", "ORANGE", "DARKGREEN", "DARKBLUE", "DARKPURPLE", "DARKBROWN",
        "GRAY", "RED", "GOLD", "LIME", "BLUE", "VIOLET", "BROWN", "LIGHTGRAY", "PINK", "YELLOW",
        "GREEN", "SKYBLUE", "PURPLE", "BEIGE",
    )

    var color_rects: array[rl.Rectangle, MAX_COLORS_COUNT] = zero[array[rl.Rectangle, MAX_COLORS_COUNT]]
    var index = 0
    while index < MAX_COLORS_COUNT:
        let column = float<-(index % 7)
        let row = float<-index / 7.0
        color_rects[index].x = 20.0 + 100.0 * column + 10.0 * column
        color_rects[index].y = 80.0 + 100.0 * float<-(index / 7) + 10.0 * row
        color_rects[index].width = 100.0
        color_rects[index].height = 100.0
        index += 1

    var color_state: array[int, MAX_COLORS_COUNT] = zero[array[int, MAX_COLORS_COUNT]]
    var mouse_point = rl.Vector2(x = 0.0, y = 0.0)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        mouse_point = rl.get_mouse_position()

        index = 0
        while index < MAX_COLORS_COUNT:
            if rl.check_collision_point_rec(mouse_point, color_rects[index]):
                color_state[index] = 1
            else:
                color_state[index] = 0
            index += 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text("raylib colors palette", 28, 42, 20, rl.BLACK)
        rl.draw_text("press SPACE to see all colors", rl.get_screen_width() - 180, rl.get_screen_height() - 40, 10, rl.GRAY)

        index = 0
        while index < MAX_COLORS_COUNT:
            let alpha: float = if color_state[index] != 0: 0.6 else: 1.0
            rl.draw_rectangle_rec(color_rects[index], rl.fade(colors[index], alpha))

            if rl.is_key_down(rl.KeyboardKey.KEY_SPACE) or color_state[index] != 0:
                rl.draw_rectangle(
                    int<-color_rects[index].x,
                    int<-(color_rects[index].y + color_rects[index].height - 26.0),
                    int<-color_rects[index].width,
                    20,
                    rl.BLACK,
                )
                rl.draw_rectangle_lines_ex(color_rects[index], 6.0, rl.fade(rl.BLACK, 0.3))
                let name_width = rl.measure_text(color_names[index], 10)
                rl.draw_text(
                    color_names[index],
                    int<-(color_rects[index].x + color_rects[index].width - float<-name_width - 12.0),
                    int<-(color_rects[index].y + color_rects[index].height - 20.0),
                    10,
                    colors[index],
                )
            index += 1

        rl.end_drawing()

    return 0
