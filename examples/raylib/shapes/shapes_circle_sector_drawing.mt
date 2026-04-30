module examples.raylib.shapes.shapes_circle_sector_drawing

import std.c.libm as math
import std.c.raygui as gui
import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - circle sector drawing"
const mode_format: cstr = c"MODE: %s"
const manual_mode: cstr = c"MANUAL"
const auto_mode: cstr = c"AUTO"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var center = rl.Vector2(x = (rl.GetScreenWidth() - 300) / 2.0, y = rl.GetScreenHeight() / 2.0)
    var outer_radius: f32 = 180.0
    var start_angle: f32 = 0.0
    var end_angle: f32 = 180.0
    var segments: f32 = 10.0
    var min_segments: f32 = 4.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawLine(500, 0, 500, rl.GetScreenHeight(), rl.Fade(rl.LIGHTGRAY, 0.6))
        rl.DrawRectangle(500, 0, rl.GetScreenWidth() - 500, rl.GetScreenHeight(), rl.Fade(rl.LIGHTGRAY, 0.3))

        rl.DrawCircleSector(center, outer_radius, start_angle, end_angle, i32<-segments, rl.Fade(rl.MAROON, 0.3))
        rl.DrawCircleSectorLines(center, outer_radius, start_angle, end_angle, i32<-segments, rl.Fade(rl.MAROON, 0.6))

        gui.GuiSliderBar(gui.Rectangle(x = 600.0, y = 40.0, width = 120.0, height = 20.0), c"StartAngle", rl.TextFormat(c"%.2f", start_angle), ptr_of(ref_of(start_angle)), 0.0, 720.0)
        gui.GuiSliderBar(gui.Rectangle(x = 600.0, y = 70.0, width = 120.0, height = 20.0), c"EndAngle", rl.TextFormat(c"%.2f", end_angle), ptr_of(ref_of(end_angle)), 0.0, 720.0)
        gui.GuiSliderBar(gui.Rectangle(x = 600.0, y = 140.0, width = 120.0, height = 20.0), c"Radius", rl.TextFormat(c"%.2f", outer_radius), ptr_of(ref_of(outer_radius)), 0.0, 200.0)
        gui.GuiSliderBar(gui.Rectangle(x = 600.0, y = 170.0, width = 120.0, height = 20.0), c"Segments", rl.TextFormat(c"%.2f", segments), ptr_of(ref_of(segments)), 0.0, 100.0)

        min_segments = math.truncf(math.ceilf((end_angle - start_angle) / 90.0))

        let mode = if segments >= min_segments then manual_mode else auto_mode
        let mode_color = if segments >= min_segments then rl.MAROON else rl.DARKGRAY
        rl.DrawText(rl.TextFormat(mode_format, mode), 600, 200, 10, mode_color)

        rl.DrawFPS(10, 10)

    return 0
