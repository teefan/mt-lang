module examples.idiomatic.raylib.hilbert_curve

import std.raygui as gui
import std.raylib as rl
import std.mem.heap as heap

const screen_width: i32 = 800
const screen_height: i32 = 450
const min_order: i32 = 2
const max_order: i32 = 8
const max_stroke_count: i32 = 65536
const panel_width: f32 = 350.0

def compute_hilbert_step(order: i32, index_start: i32) -> rl.Vector2:
    let hilbert_points = array[rl.Vector2, 4](
        rl.Vector2(x = 0.0, y = 0.0),
        rl.Vector2(x = 0.0, y = 1.0),
        rl.Vector2(x = 1.0, y = 1.0),
        rl.Vector2(x = 1.0, y = 0.0),
    )

    var index = index_start
    var hilbert_index = index & 3
    var vect = hilbert_points[hilbert_index]
    var temp: f32 = 0.0
    var len = 0

    for level in range(1, order):
        index = index >> 2
        hilbert_index = index & 3
        len = 1 << level

        if hilbert_index == 0:
            temp = vect.x
            vect.x = vect.y
            vect.y = temp
        elif hilbert_index == 1:
            vect.y += f32<-len
        elif hilbert_index == 2:
            vect.x += f32<-len
            vect.y += f32<-len
        elif hilbert_index == 3:
            temp = f32<-(len - 1) - vect.x
            vect.x = f32<-(2 * len - 1) - vect.y
            vect.y = temp

    return vect

def rebuild_path(mut hilbert_path: span[rl.Vector2], order: i32, size: f32) -> i32:
    let path_count = 1 << order
    let stroke_count = path_count * path_count
    let path_len = size / f32<-path_count

    for index in range(0, stroke_count):
        hilbert_path[index] = compute_hilbert_step(order, index)
        hilbert_path[index].x = hilbert_path[index].x * path_len + path_len / 2.0
        hilbert_path[index].y = hilbert_path[index].y * path_len + path_len / 2.0

    return stroke_count

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Hilbert Curve")
    defer rl.close_window()

    var order = min_order
    var size: f32 = f32<-rl.get_screen_height()
    var stroke_count = 0
    let hilbert_storage = heap.must_alloc_zeroed[rl.Vector2](usize<-max_stroke_count)
    defer heap.release(hilbert_storage)
    var path_view = span[rl.Vector2](data = hilbert_storage, len = usize<-max_stroke_count)

    var previous_order = order
    var previous_size = i32<-size
    var counter = 0
    var thick: f32 = 2.0
    var animate = true

    let screen_height_value = f32<-rl.get_screen_height()
    let panel_margin: f32 = 5.0
    let panel_position = rl.Vector2(x = f32<-screen_width - panel_margin - panel_width, y = panel_margin)
    let size_max = screen_height_value * 1.5

    stroke_count = rebuild_path(path_view, order, size)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        var should_reload = previous_order != order
        if not should_reload:
            should_reload = previous_size != i32<-size

        if should_reload:
            stroke_count = rebuild_path(path_view, order, size)

            if animate:
                counter = 0
            else:
                counter = stroke_count

            previous_order = order
            previous_size = i32<-size

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        if counter < stroke_count:
            for index in range(1, counter + 1):
                let hue = f32<-index / f32<-stroke_count * 360.0
                rl.draw_line_ex(path_view[index], path_view[index - 1], thick, rl.color_from_hsv(hue, 1.0, 1.0))

            counter += 1
        else:
            for index in range(1, stroke_count):
                let hue = f32<-index / f32<-stroke_count * 360.0
                rl.draw_line_ex(path_view[index], path_view[index - 1], thick, rl.color_from_hsv(hue, 1.0, 1.0))

        gui.check_box(rl.Rectangle(x = 450.0, y = 50.0, width = 20.0, height = 20.0), "ANIMATE GENERATION ON CHANGE", inout animate)
        gui.spinner(rl.Rectangle(x = 585.0, y = 100.0, width = 180.0, height = 30.0), "HILBERT CURVE ORDER:  ", inout order, min_order, max_order, false)
        gui.slider(rl.Rectangle(x = 524.0, y = 150.0, width = 240.0, height = 24.0), "THICKNESS:  ", "", inout thick, 1.0, 10.0)
        gui.slider(rl.Rectangle(x = 524.0, y = 190.0, width = 240.0, height = 24.0), "TOTAL SIZE: ", "", inout size, 10.0, size_max)
        rl.draw_rectangle_lines_ex(
            rl.Rectangle(
                x = panel_position.x - 10.0,
                y = panel_position.y + 35.0,
                width = panel_width - 20.0,
                height = 190.0,
            ),
            1.0,
            rl.fade(rl.LIGHTGRAY, 0.6),
        )

    return 0
