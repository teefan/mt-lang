module examples.raylib.shapes.shapes_kaleidoscope

import std.c.raygui as gui
import std.c.raylib as rl
import std.raylib.math as mt_math

struct Line:
    start: rl.Vector2
    finish: rl.Vector2

const max_draw_lines: i32 = 8192
const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - kaleidoscope"
const back_button_text: cstr = c"<"
const next_button_text: cstr = c">"
const reset_button_text: cstr = c"Reset"
const lines_format: cstr = c"LINES: %i/%i"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var lines = zero[array[Line, 8192]]

    var symmetry: i32 = 6
    let angle = 360.0 / f32<-symmetry
    let thickness: f32 = 3.0
    let reset_button_rec = rl.Rectangle(x = screen_width - 55.0, y = 5.0, width = 50.0, height = 25.0)
    let back_button_rec = rl.Rectangle(x = screen_width - 55.0, y = screen_height - 30.0, width = 25.0, height = 25.0)
    let next_button_rec = rl.Rectangle(x = screen_width - 30.0, y = screen_height - 30.0, width = 25.0, height = 25.0)
    let reset_button_gui_rec = gui.Rectangle(x = screen_width - 55.0, y = 5.0, width = 50.0, height = 25.0)
    let back_button_gui_rec = gui.Rectangle(x = screen_width - 55.0, y = screen_height - 30.0, width = 25.0, height = 25.0)
    let next_button_gui_rec = gui.Rectangle(x = screen_width - 30.0, y = screen_height - 30.0, width = 25.0, height = 25.0)
    var mouse_pos = rl.Vector2.zero()
    var prev_mouse_pos = rl.Vector2.zero()
    let scale_vector = rl.Vector2(x = 1.0, y = -1.0)
    let offset = rl.Vector2(x = screen_width / 2.0, y = screen_height / 2.0)

    let camera = rl.Camera2D(
        offset = offset,
        target = rl.Vector2.zero(),
        rotation = 0.0,
        zoom = 1.0,
    )

    var current_line_counter = 0
    var total_line_counter = 0
    var reset_button_clicked = false
    var back_button_clicked = false
    var next_button_clicked = false

    rl.SetTargetFPS(20)

    while not rl.WindowShouldClose():
        prev_mouse_pos = mouse_pos
        mouse_pos = rl.GetMousePosition()

        let base_line_start = mouse_pos.subtract(offset)
        let base_line_end = prev_mouse_pos.subtract(offset)

        if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT):
            if not rl.CheckCollisionPointRec(mouse_pos, reset_button_rec):
                if not rl.CheckCollisionPointRec(mouse_pos, back_button_rec):
                    if not rl.CheckCollisionPointRec(mouse_pos, next_button_rec):
                        var line_start = base_line_start
                        var line_end = base_line_end

                        for _ in 0..symmetry:
                            if total_line_counter >= max_draw_lines - 1:
                                break

                            line_start = line_start.rotate(angle * mt_math.deg2rad)
                            line_end = line_end.rotate(angle * mt_math.deg2rad)

                            lines[total_line_counter] = Line(start = line_start, finish = line_end)
                            lines[total_line_counter + 1] = Line(
                                start = line_start.multiply(scale_vector),
                                finish = line_end.multiply(scale_vector),
                            )

                            total_line_counter += 2
                            current_line_counter = total_line_counter

        if reset_button_clicked:
            current_line_counter = 0
            total_line_counter = 0

        if back_button_clicked and current_line_counter > 0:
            current_line_counter -= 1

        if next_button_clicked and current_line_counter < max_draw_lines and current_line_counter + 1 <= total_line_counter:
            current_line_counter += 1

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode2D(camera)

        for _ in 0..symmetry:
            var index = 0
            while index < current_line_counter:
                rl.DrawLineEx(lines[index].start, lines[index].finish, thickness, rl.BLACK)
                rl.DrawLineEx(lines[index + 1].start, lines[index + 1].finish, thickness, rl.BLACK)
                index += 2

        rl.EndMode2D()

        if current_line_counter - 1 < 0:
            gui.GuiDisable()

        back_button_clicked = gui.GuiButton(back_button_gui_rec, back_button_text) != 0
        gui.GuiEnable()

        if current_line_counter + 1 > total_line_counter:
            gui.GuiDisable()

        next_button_clicked = gui.GuiButton(next_button_gui_rec, next_button_text) != 0
        gui.GuiEnable()
        reset_button_clicked = gui.GuiButton(reset_button_gui_rec, reset_button_text) != 0

        rl.DrawText(rl.TextFormat(lines_format, current_line_counter, max_draw_lines), 10, screen_height - 30, 20, rl.MAROON)
        rl.DrawFPS(10, 10)

    return 0
