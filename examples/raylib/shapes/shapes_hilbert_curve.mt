module examples.raylib.shapes.shapes_hilbert_curve

import std.c.raygui as gui
import std.c.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const min_order: int = 2
const max_order: int = 8
const max_stroke_count: int = 65536
const panel_width: float = 350.0
const window_title: cstr = c"raylib [shapes] example - hilbert curve"
const animate_text: cstr = c"ANIMATE GENERATION ON CHANGE"
const order_text: cstr = c"HILBERT CURVE ORDER:  "
const thickness_text: cstr = c"THICKNESS:  "
const size_text: cstr = c"TOTAL SIZE: "
const empty_text: cstr = c""


def compute_hilbert_step(order: int, index_start: int) -> rl.Vector2:
    let hilbert_points = array[rl.Vector2, 4](
        rl.Vector2(x = 0.0, y = 0.0),
        rl.Vector2(x = 0.0, y = 1.0),
        rl.Vector2(x = 1.0, y = 1.0),
        rl.Vector2(x = 1.0, y = 0.0),
    )

    var index = index_start
    var hilbert_index = index & 3
    var vect = hilbert_points[hilbert_index]
    var temp: float = 0.0
    var len = 0

    for level in 1..order:
        index = index >> 2
        hilbert_index = index & 3
        len = 1 << level

        if hilbert_index == 0:
            temp = vect.x
            vect.x = vect.y
            vect.y = temp
        elif hilbert_index == 1:
            vect.y += float<-len
        elif hilbert_index == 2:
            vect.x += float<-len
            vect.y += float<-len
        elif hilbert_index == 3:
            temp = float<-(len - 1) - vect.x
            vect.x = float<-(2 * len - 1) - vect.y
            vect.y = temp

    return vect


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var order = min_order
    var size: float = float<-rl.GetScreenHeight()
    var stroke_count = 0
    var hilbert_path = zero[array[rl.Vector2, 65536]]

    var previous_order = order
    var previous_size = int<-size
    var counter = 0
    var thick: float = 2.0
    var animate = true

    let screen_height_value = float<-rl.GetScreenHeight()
    let panel_margin: float = 5.0
    let panel_position = rl.Vector2(
        x = float<-screen_width - panel_margin - panel_width,
        y = panel_margin,
    )
    let size_max = screen_height_value * float<-1.5

    let path_count = 1 << order
    stroke_count = path_count * path_count
    let path_len = size / float<-path_count
    for index in 0..stroke_count:
        hilbert_path[index] = compute_hilbert_step(order, index)
        hilbert_path[index].x = hilbert_path[index].x * path_len + path_len / 2.0
        hilbert_path[index].y = hilbert_path[index].y * path_len + path_len / 2.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        var should_reload = previous_order != order
        if not should_reload:
            should_reload = previous_size != int<-size

        if should_reload:
            let new_path_count = 1 << order
            stroke_count = new_path_count * new_path_count
            let new_path_len = size / float<-new_path_count

            for index in 0..stroke_count:
                hilbert_path[index] = compute_hilbert_step(order, index)
                hilbert_path[index].x = hilbert_path[index].x * new_path_len + new_path_len / 2.0
                hilbert_path[index].y = hilbert_path[index].y * new_path_len + new_path_len / 2.0

            if animate:
                counter = 0
            else:
                counter = stroke_count

            previous_order = order
            previous_size = int<-size

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        if counter < stroke_count:
            for index in 1..counter + 1:
                let hue = float<-index / float<-stroke_count * 360.0
                rl.DrawLineEx(hilbert_path[index], hilbert_path[index - 1], thick, rl.ColorFromHSV(hue, 1.0, 1.0))

            counter += 1
        else:
            for index in 1..stroke_count:
                let hue = float<-index / float<-stroke_count * 360.0
                rl.DrawLineEx(hilbert_path[index], hilbert_path[index - 1], thick, rl.ColorFromHSV(hue, 1.0, 1.0))

        gui.GuiCheckBox(gui.Rectangle(x = 450.0, y = 50.0, width = 20.0, height = 20.0), animate_text, ptr_of(animate))
        gui.GuiSpinner(gui.Rectangle(x = 585.0, y = 100.0, width = 180.0, height = 30.0), order_text, ptr_of(order), min_order, max_order, false)
        gui.GuiSlider(gui.Rectangle(x = 524.0, y = 150.0, width = 240.0, height = 24.0), thickness_text, empty_text, ptr_of(thick), 1.0, 10.0)
        gui.GuiSlider(gui.Rectangle(x = 524.0, y = 190.0, width = 240.0, height = 24.0), size_text, empty_text, ptr_of(size), 10.0, size_max)
        rl.DrawRectangleLinesEx(
            rl.Rectangle(
                x = panel_position.x - 10.0,
                y = panel_position.y + 35.0,
                width = panel_width - 20.0,
                height = 190.0,
            ),
            1.0,
            rl.Fade(rl.LIGHTGRAY, 0.6),
        )

    return 0
