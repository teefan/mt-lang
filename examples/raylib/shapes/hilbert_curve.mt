import std.raygui as gui
import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_HILBERT_STROKES: int = 65536


var hilbert_path: array[rl.Vector2, MAX_HILBERT_STROKES] = zero[array[rl.Vector2, MAX_HILBERT_STROKES]]


function load_hilbert_path(order: int, size: float) -> int:
    let n = 1 << order
    let segment_length = size / float<-n
    let stroke_count = n * n

    var index = 0
    while index < stroke_count:
        hilbert_path[index] = compute_hilbert_step(order, index)
        hilbert_path[index].x = hilbert_path[index].x * segment_length + segment_length / 2.0
        hilbert_path[index].y = hilbert_path[index].y * segment_length + segment_length / 2.0
        index += 1

    return stroke_count


function compute_hilbert_step(order: int, index: int) -> rl.Vector2:
    let hilbert_points = array[rl.Vector2, 4](
        rl.Vector2(x = 0.0, y = 0.0),
        rl.Vector2(x = 0.0, y = 1.0),
        rl.Vector2(x = 1.0, y = 1.0),
        rl.Vector2(x = 1.0, y = 0.0),
    )

    var current_index = index
    var hilbert_index = current_index & 3
    var vect = hilbert_points[hilbert_index]
    var length = 0

    var level = 1
    while level < order:
        current_index = current_index >> 2
        hilbert_index = current_index & 3
        length = 1 << level

        if hilbert_index == 0:
            let temp = vect.x
            vect.x = vect.y
            vect.y = temp
        else if hilbert_index == 1:
            vect.y += float<-length
        else if hilbert_index == 2:
            vect.x += float<-length
            vect.y += float<-length
        else:
            let temp = float<-length - 1.0 - vect.x
            vect.x = (2.0 * float<-length) - 1.0 - vect.y
            vect.y = temp

        level += 1

    return vect


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - hilbert curve")
    defer rl.close_window()

    var order = 2
    var size: float = float<-rl.get_screen_height()
    var stroke_count = load_hilbert_path(order, size)

    var prev_order = order
    var prev_size = int<-size
    var counter = 0
    var thick: float = 2.0
    var animate = true

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if prev_order != order or prev_size != int<-size:
            stroke_count = load_hilbert_path(order, size)

            if animate:
                counter = 0
            else:
                counter = stroke_count

            prev_order = order
            prev_size = int<-size

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        if counter < stroke_count:
            var index = 1
            while index <= counter:
                rl.draw_line_ex(
                    hilbert_path[index],
                    hilbert_path[index - 1],
                    thick,
                    rl.color_from_hsv((float<-index / float<-stroke_count) * 360.0, 1.0, 1.0),
                )
                index += 1

            counter += 1
        else:
            var index = 1
            while index < stroke_count:
                rl.draw_line_ex(
                    hilbert_path[index],
                    hilbert_path[index - 1],
                    thick,
                    rl.color_from_hsv((float<-index / float<-stroke_count) * 360.0, 1.0, 1.0),
                )
                index += 1

        gui.check_box(rl.Rectangle(x = 450.0, y = 50.0, width = 20.0, height = 20.0), "ANIMATE GENERATION ON CHANGE", animate)
        gui.spinner(rl.Rectangle(x = 585.0, y = 100.0, width = 180.0, height = 30.0), "HILBERT CURVE ORDER:  ", order, 2, 8, false)
        gui.slider(rl.Rectangle(x = 524.0, y = 150.0, width = 240.0, height = 24.0), "THICKNESS:  ", "", thick, 1.0, 10.0)
        gui.slider(rl.Rectangle(x = 524.0, y = 190.0, width = 240.0, height = 24.0), "TOTAL SIZE: ", "", size, 10.0, float<-rl.get_screen_height() * 1.5)
        rl.end_drawing()

    return 0
