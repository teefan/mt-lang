module examples.raylib.core.core_highdpi_demo

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const cell_size: i32 = 50
const window_title: cstr = c"raylib [core] example - highdpi demo"
const sample_text: cstr = c"Can you see this?"

def draw_text_center(text: cstr, x: i32, y: i32, font_size: i32, color: rl.Color) -> void:
    let font = rl.GetFontDefault()
    let size = rl.MeasureTextEx(font, text, font_size, 3.0)
    rl.DrawTextEx(
        font,
        text,
        rl.Vector2(
            x = x - size.x / 2.0,
            y = y - size.y / 2.0,
        ),
        font_size,
        3.0,
        color,
    )

def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_WINDOW_HIGHDPI | rl.ConfigFlags.FLAG_WINDOW_RESIZABLE)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()
    rl.SetWindowMinSize(450, 450)

    let logical_grid_desc_y = 120
    let logical_grid_label_y = logical_grid_desc_y + 30
    let logical_grid_top = logical_grid_label_y + 30
    let logical_grid_bottom = logical_grid_top + 80
    let pixel_grid_top = logical_grid_bottom - 20
    let pixel_grid_bottom = pixel_grid_top + 80
    let pixel_grid_label_y = pixel_grid_bottom + 30
    let pixel_grid_desc_y = pixel_grid_label_y + 30
    var cell_size_px: f32 = cast[f32](cell_size)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let monitor_count = rl.GetMonitorCount()
        if monitor_count > 1 and rl.IsKeyPressed(rl.KeyboardKey.KEY_N):
            rl.SetWindowMonitor((rl.GetCurrentMonitor() + 1) % monitor_count)

        let current_monitor = rl.GetCurrentMonitor()
        let dpi_scale = rl.GetWindowScaleDPI()
        cell_size_px = cast[f32](cell_size) / dpi_scale.x

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        let window_center = rl.GetScreenWidth() / 2
        draw_text_center(rl.TextFormat(c"Dpi Scale: %.6f", dpi_scale.x), window_center, 30, 40, rl.DARKGRAY)

        draw_text_center(rl.TextFormat(c"Monitor: %i/%i ([N] next monitor)", current_monitor + 1, monitor_count), window_center, 70, 20, rl.LIGHTGRAY)

        draw_text_center(rl.TextFormat(c"Window is %i \"logical points\" wide", rl.GetScreenWidth()), window_center, logical_grid_desc_y, 20, rl.ORANGE)

        var odd = true
        var logical_x = cell_size
        while logical_x < rl.GetScreenWidth():
            if odd:
                rl.DrawRectangle(logical_x, logical_grid_top, cell_size, logical_grid_bottom - logical_grid_top, rl.ORANGE)

            draw_text_center(rl.TextFormat(c"%i", logical_x), logical_x, logical_grid_label_y, 10, rl.LIGHTGRAY)
            rl.DrawLine(logical_x, logical_grid_label_y + 10, logical_x, logical_grid_bottom, rl.GRAY)
            odd = not odd
            logical_x += cell_size

        odd = true
        let min_text_space = 30
        var last_text_x = -min_text_space
        var pixel_x = cell_size
        while pixel_x < rl.GetRenderWidth():
            let x: i32 = cast[i32](cast[f32](pixel_x) / dpi_scale.x)
            if odd:
                rl.DrawRectangle(
                    x,
                    pixel_grid_top,
                    cell_size_px,
                    pixel_grid_bottom - pixel_grid_top,
                    rl.Color(r = 0, g = 121, b = 241, a = 100),
                )
            rl.DrawLine(x, pixel_grid_top, x, pixel_grid_label_y - 10, rl.GRAY)

            if x - last_text_x >= min_text_space:
                draw_text_center(rl.TextFormat(c"%i", pixel_x), x, pixel_grid_label_y, 10, rl.LIGHTGRAY)
                last_text_x = x

            odd = not odd
            pixel_x += cell_size

        draw_text_center(rl.TextFormat(c"Window is %i \"physical pixels\" wide", rl.GetRenderWidth()), window_center, pixel_grid_desc_y, 20, rl.BLUE)

        let font = rl.GetFontDefault()
        let sample_size = rl.MeasureTextEx(font, sample_text, 20.0, 3.0)
        rl.DrawTextEx(
            font,
            sample_text,
            rl.Vector2(
                x = rl.GetScreenWidth() - sample_size.x - 5.0,
                y = rl.GetScreenHeight() - sample_size.y - 5.0,
            ),
            20.0,
            3.0,
            rl.LIGHTGRAY,
        )

    return 0
