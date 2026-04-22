module examples.raylib.core.core_highdpi_demo

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const cell_size: i32 = 50
const window_title: cstr = c"raylib [core] example - highdpi demo"
const help_text: cstr = c"Press N to move window to next monitor"
const logical_text: cstr = c"LOGICAL POINTS"
const physical_text: cstr = c"PHYSICAL PIXELS"
const sample_text: cstr = c"Can you see this?"

def draw_text_center(text: cstr, x: i32, y: i32, font_size: i32, color: rl.Color) -> void:
    let font = rl.GetFontDefault()
    let size = rl.MeasureTextEx(font, text, 1.0 * font_size, 3.0)
    rl.DrawTextEx(
        font,
        text,
        rl.Vector2(
            x = 1.0 * x - size.x / 2.0,
            y = 1.0 * y - size.y / 2.0,
        ),
        1.0 * font_size,
        3.0,
        color,
    )

def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_WINDOW_HIGHDPI | rl.ConfigFlags.FLAG_WINDOW_RESIZABLE)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()
    rl.SetWindowMinSize(450, 450)

    let logical_grid_desc_y = 120
    let logical_grid_top = logical_grid_desc_y + 60
    let logical_grid_bottom = logical_grid_top + 80
    let pixel_grid_top = logical_grid_bottom - 20
    let pixel_grid_bottom = pixel_grid_top + 80
    let pixel_grid_desc_y = pixel_grid_bottom + 60
    var cell_size_px: f32 = 1.0 * cell_size

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let monitor_count = rl.GetMonitorCount()
        if monitor_count > 1 and rl.IsKeyPressed(rl.KeyboardKey.KEY_N):
            rl.SetWindowMonitor((rl.GetCurrentMonitor() + 1) % monitor_count)

        let dpi_scale = rl.GetWindowScaleDPI()
        cell_size_px = 1.0 * cell_size / dpi_scale.x

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        let window_center = rl.GetScreenWidth() / 2
        draw_text_center(help_text, window_center, 30, 20, rl.DARKGRAY)
        draw_text_center(logical_text, window_center, logical_grid_desc_y, 20, rl.ORANGE)

        var odd = true
        var logical_x = cell_size
        while logical_x < rl.GetScreenWidth():
            if odd:
                rl.DrawRectangle(logical_x, logical_grid_top, cell_size, logical_grid_bottom - logical_grid_top, rl.ORANGE)
            rl.DrawLine(logical_x, logical_grid_top, logical_x, logical_grid_bottom, rl.GRAY)
            odd = not odd
            logical_x += cell_size

        odd = true
        var pixel_x = cell_size
        while pixel_x < rl.GetRenderWidth():
            let x = cast[i32](1.0 * pixel_x / dpi_scale.x)
            if odd:
                rl.DrawRectangle(
                    x,
                    pixel_grid_top,
                    cast[i32](cell_size_px),
                    pixel_grid_bottom - pixel_grid_top,
                    rl.Color(r = 0, g = 121, b = 241, a = 100),
                )
            rl.DrawLine(x, pixel_grid_top, x, pixel_grid_bottom, rl.GRAY)
            odd = not odd
            pixel_x += cell_size

        draw_text_center(physical_text, window_center, pixel_grid_desc_y, 20, rl.BLUE)

        let font = rl.GetFontDefault()
        let sample_size = rl.MeasureTextEx(font, sample_text, 20.0, 3.0)
        rl.DrawTextEx(
            font,
            sample_text,
            rl.Vector2(
                x = 1.0 * rl.GetScreenWidth() - sample_size.x - 5.0,
                y = 1.0 * rl.GetScreenHeight() - sample_size.y - 5.0,
            ),
            20.0,
            3.0,
            rl.LIGHTGRAY,
        )

    return 0
