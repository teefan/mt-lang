module examples.raylib.shapes.shapes_ring_drawing

import std.c.libm as math
import std.c.raygui as gui
import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - ring drawing"
const mode_format: cstr = c"MODE: %s"
const manual_mode: cstr = c"MANUAL"
const auto_mode: cstr = c"AUTO"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var center = rl.Vector2(x = (rl.GetScreenWidth() - 300) / 2.0, y = rl.GetScreenHeight() / 2.0)
    var inner_radius: f32 = 80.0
    var outer_radius: f32 = 190.0
    var start_angle: f32 = 0.0
    var end_angle: f32 = 360.0
    var segments: f32 = 0.0

    var draw_ring = true
    var draw_ring_lines = false
    var draw_circle_lines = false

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawLine(500, 0, 500, rl.GetScreenHeight(), rl.Fade(rl.LIGHTGRAY, 0.6))
        rl.DrawRectangle(500, 0, rl.GetScreenWidth() - 500, rl.GetScreenHeight(), rl.Fade(rl.LIGHTGRAY, 0.3))

        if draw_ring:
            rl.DrawRing(center, inner_radius, outer_radius, start_angle, end_angle, i32<-segments, rl.Fade(rl.MAROON, 0.3))

        if draw_ring_lines:
            rl.DrawRingLines(center, inner_radius, outer_radius, start_angle, end_angle, i32<-segments, rl.Fade(rl.BLACK, 0.4))

        if draw_circle_lines:
            rl.DrawCircleSectorLines(center, outer_radius, start_angle, end_angle, i32<-segments, rl.Fade(rl.BLACK, 0.4))

        gui.GuiSliderBar(gui.Rectangle(x = 600.0, y = 40.0, width = 120.0, height = 20.0), c"StartAngle", rl.TextFormat(c"%.2f", start_angle), ptr_of(ref_of(start_angle)), -450.0, 450.0)
        gui.GuiSliderBar(gui.Rectangle(x = 600.0, y = 70.0, width = 120.0, height = 20.0), c"EndAngle", rl.TextFormat(c"%.2f", end_angle), ptr_of(ref_of(end_angle)), -450.0, 450.0)
        gui.GuiSliderBar(gui.Rectangle(x = 600.0, y = 140.0, width = 120.0, height = 20.0), c"InnerRadius", rl.TextFormat(c"%.2f", inner_radius), ptr_of(ref_of(inner_radius)), 0.0, 100.0)
        gui.GuiSliderBar(gui.Rectangle(x = 600.0, y = 170.0, width = 120.0, height = 20.0), c"OuterRadius", rl.TextFormat(c"%.2f", outer_radius), ptr_of(ref_of(outer_radius)), 0.0, 200.0)
        gui.GuiSliderBar(gui.Rectangle(x = 600.0, y = 240.0, width = 120.0, height = 20.0), c"Segments", rl.TextFormat(c"%.2f", segments), ptr_of(ref_of(segments)), 0.0, 100.0)

        gui.GuiCheckBox(gui.Rectangle(x = 600.0, y = 320.0, width = 20.0, height = 20.0), c"Draw Ring", ptr_of(ref_of(draw_ring)))
        gui.GuiCheckBox(gui.Rectangle(x = 600.0, y = 350.0, width = 20.0, height = 20.0), c"Draw RingLines", ptr_of(ref_of(draw_ring_lines)))
        gui.GuiCheckBox(gui.Rectangle(x = 600.0, y = 380.0, width = 20.0, height = 20.0), c"Draw CircleLines", ptr_of(ref_of(draw_circle_lines)))

        let min_segments = i32<-math.ceilf((end_angle - start_angle) / 90.0)
        let mode = if segments >= f32<-min_segments: manual_mode else: auto_mode
        let mode_color = if segments >= f32<-min_segments: rl.MAROON else: rl.DARKGRAY
        rl.DrawText(rl.TextFormat(mode_format, mode), 600, 270, 10, mode_color)

        rl.DrawFPS(10, 10)

    return 0
