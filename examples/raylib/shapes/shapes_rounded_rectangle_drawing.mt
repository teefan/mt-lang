module examples.raylib.shapes.shapes_rounded_rectangle_drawing

import std.c.raygui as gui
import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - rounded rectangle drawing"
const mode_format: cstr = c"MODE: %s"
const manual_mode: cstr = c"MANUAL"
const auto_mode: cstr = c"AUTO"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var roundness: f32 = 0.2
    var width: f32 = 200.0
    var height: f32 = 100.0
    var segments: f32 = 0.0
    var line_thick: f32 = 1.0

    var draw_rect = false
    var draw_rounded_rect = true
    var draw_rounded_lines = false

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let rec = rl.Rectangle(
            x = (f32<-rl.GetScreenWidth() - width - 250.0) / 2.0,
            y = (f32<-rl.GetScreenHeight() - height) / 2.0,
            width = width,
            height = height,
        )

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawLine(560, 0, 560, rl.GetScreenHeight(), rl.Fade(rl.LIGHTGRAY, 0.6))
        rl.DrawRectangle(560, 0, rl.GetScreenWidth() - 500, rl.GetScreenHeight(), rl.Fade(rl.LIGHTGRAY, 0.3))

        if draw_rect:
            rl.DrawRectangleRec(rec, rl.Fade(rl.GOLD, 0.6))

        if draw_rounded_rect:
            rl.DrawRectangleRounded(rec, roundness, i32<-segments, rl.Fade(rl.MAROON, 0.2))

        if draw_rounded_lines:
            rl.DrawRectangleRoundedLinesEx(rec, roundness, i32<-segments, line_thick, rl.Fade(rl.MAROON, 0.4))

        gui.GuiSliderBar(gui.Rectangle(x = 640.0, y = 40.0, width = 105.0, height = 20.0), c"Width", rl.TextFormat(c"%.2f", width), ptr_of(ref_of(width)), 0.0, f32<-rl.GetScreenWidth() - 300.0)
        gui.GuiSliderBar(gui.Rectangle(x = 640.0, y = 70.0, width = 105.0, height = 20.0), c"Height", rl.TextFormat(c"%.2f", height), ptr_of(ref_of(height)), 0.0, f32<-rl.GetScreenHeight() - 50.0)
        gui.GuiSliderBar(gui.Rectangle(x = 640.0, y = 140.0, width = 105.0, height = 20.0), c"Roundness", rl.TextFormat(c"%.2f", roundness), ptr_of(ref_of(roundness)), 0.0, 1.0)
        gui.GuiSliderBar(gui.Rectangle(x = 640.0, y = 170.0, width = 105.0, height = 20.0), c"Thickness", rl.TextFormat(c"%.2f", line_thick), ptr_of(ref_of(line_thick)), 0.0, 20.0)
        gui.GuiSliderBar(gui.Rectangle(x = 640.0, y = 240.0, width = 105.0, height = 20.0), c"Segments", rl.TextFormat(c"%.2f", segments), ptr_of(ref_of(segments)), 0.0, 60.0)

        gui.GuiCheckBox(gui.Rectangle(x = 640.0, y = 320.0, width = 20.0, height = 20.0), c"DrawRoundedRect", ptr_of(ref_of(draw_rounded_rect)))
        gui.GuiCheckBox(gui.Rectangle(x = 640.0, y = 350.0, width = 20.0, height = 20.0), c"DrawRoundedLines", ptr_of(ref_of(draw_rounded_lines)))
        gui.GuiCheckBox(gui.Rectangle(x = 640.0, y = 380.0, width = 20.0, height = 20.0), c"DrawRect", ptr_of(ref_of(draw_rect)))

        let mode = if segments >= 4.0 then manual_mode else auto_mode
        let mode_color = if segments >= 4.0 then rl.MAROON else rl.DARKGRAY
        rl.DrawText(rl.TextFormat(mode_format, mode), 640, 280, 10, mode_color)

        rl.DrawFPS(10, 10)

    return 0
