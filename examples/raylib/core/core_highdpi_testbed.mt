module examples.raylib.core.core_highdpi_testbed

import std.c.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const grid_spacing: int = 40
const window_title: cstr = c"raylib [core] example - highdpi testbed"


def main() -> int:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_WINDOW_RESIZABLE | rl.ConfigFlags.FLAG_WINDOW_HIGHDPI)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var scale_dpi = rl.GetWindowScaleDPI()
    var mouse_pos = rl.GetMousePosition()
    var current_monitor = rl.GetCurrentMonitor()
    var window_pos = rl.GetWindowPosition()

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        mouse_pos = rl.GetMousePosition()
        current_monitor = rl.GetCurrentMonitor()
        scale_dpi = rl.GetWindowScaleDPI()
        window_pos = rl.GetWindowPosition()

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            rl.ToggleBorderlessWindowed()
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_F):
            rl.ToggleFullscreen()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        let horizontal_lines = rl.GetScreenHeight() / grid_spacing + 1
        var h = 0
        while h < horizontal_lines:
            rl.DrawText(rl.TextFormat(c"%02i", h * grid_spacing), 4, h * grid_spacing - 4, 10, rl.GRAY)
            rl.DrawLine(24, h * grid_spacing, rl.GetScreenWidth(), h * grid_spacing, rl.LIGHTGRAY)
            h += 1

        let vertical_lines = rl.GetScreenWidth() / grid_spacing + 1
        var v = 0
        while v < vertical_lines:
            rl.DrawText(rl.TextFormat(c"%02i", v * grid_spacing), v * grid_spacing - 10, 4, 10, rl.GRAY)
            rl.DrawLine(v * grid_spacing, 20, v * grid_spacing, rl.GetScreenHeight(), rl.LIGHTGRAY)
            v += 1

        rl.DrawText(rl.TextFormat(c"CURRENT MONITOR: %i/%i (%ix%i)", current_monitor + 1, rl.GetMonitorCount(), rl.GetMonitorWidth(current_monitor), rl.GetMonitorHeight(current_monitor)), 50, 50, 20, rl.DARKGRAY)

        rl.DrawText(rl.TextFormat(c"WINDOW POSITION: %ix%i", int<-window_pos.x, int<-window_pos.y), 50, 90, 20, rl.DARKGRAY)

        rl.DrawText(rl.TextFormat(c"SCREEN SIZE: %ix%i", rl.GetScreenWidth(), rl.GetScreenHeight()), 50, 130, 20, rl.DARKGRAY)

        rl.DrawText(rl.TextFormat(c"RENDER SIZE: %ix%i", rl.GetRenderWidth(), rl.GetRenderHeight()), 50, 170, 20, rl.DARKGRAY)

        rl.DrawText(rl.TextFormat(c"SCALE FACTOR: %.2fx%.2f", scale_dpi.x, scale_dpi.y), 50, 210, 20, rl.GRAY)

        rl.DrawRectangle(0, 0, 30, 60, rl.RED)
        rl.DrawRectangle(rl.GetScreenWidth() - 30, rl.GetScreenHeight() - 60, 30, 60, rl.BLUE)

        rl.DrawCircleV(mouse_pos, 20.0, rl.MAROON)
        rl.DrawRectangleRec(
            rl.Rectangle(x = mouse_pos.x - 25.0, y = mouse_pos.y, width = 50.0, height = 2.0),
            rl.BLACK,
        )
        rl.DrawRectangleRec(
            rl.Rectangle(x = mouse_pos.x, y = mouse_pos.y - 25.0, width = 2.0, height = 50.0),
            rl.BLACK,
        )

        let mouse_text_y = if mouse_pos.y > rl.GetScreenHeight() - 60: int<-mouse_pos.y - 46 else: int<-mouse_pos.y + 30

        rl.DrawText(rl.TextFormat(c"[%i,%i]", rl.GetMouseX(), rl.GetMouseY()), mouse_pos.x - 44, mouse_text_y, 20, rl.BLACK)

    return 0
