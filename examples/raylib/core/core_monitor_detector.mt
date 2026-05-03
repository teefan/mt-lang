module examples.raylib.core.core_monitor_detector

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - monitor detector"
const help_text: cstr = c"Press [Enter] to move window to next monitor available"
const current_label: cstr = c"CURRENT"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var current_monitor_index = rl.GetCurrentMonitor()

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        var max_width = 1
        var max_height = 1
        var monitor_offset_x = 0
        let monitor_count = rl.GetMonitorCount()

        var index = 0
        while index < monitor_count:
            let position = rl.GetMonitorPosition(index)
            let width = rl.GetMonitorWidth(index)
            let height = rl.GetMonitorHeight(index)

            if position.x < monitor_offset_x:
                monitor_offset_x = -i32<-position.x

            let right_edge = i32<-position.x + width
            let bottom_edge = i32<-position.y + height
            if max_width < right_edge:
                max_width = right_edge
            if max_height < bottom_edge:
                max_height = bottom_edge

            index += 1

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_ENTER) and monitor_count > 1:
            current_monitor_index += 1
            if current_monitor_index == monitor_count:
                current_monitor_index = 0
            rl.SetWindowMonitor(current_monitor_index)
        else:
            current_monitor_index = rl.GetCurrentMonitor()

        var monitor_scale: f32 = 0.6
        if max_height > max_width + monitor_offset_x:
            monitor_scale *= f32<-screen_height / max_height
        else:
            monitor_scale *= f32<-screen_width / (max_width + monitor_offset_x)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawText(help_text, 20, 20, 20, rl.DARKGRAY)
        rl.DrawRectangleLines(20, 60, screen_width - 40, screen_height - 100, rl.DARKGRAY)

        var draw_index = 0
        while draw_index < monitor_count:
            let position = rl.GetMonitorPosition(draw_index)
            let width = rl.GetMonitorWidth(draw_index)
            let height = rl.GetMonitorHeight(draw_index)
            let rec = rl.Rectangle(
                x = (position.x + monitor_offset_x) * monitor_scale + 140.0,
                y = position.y * monitor_scale + 80.0,
                width = width * monitor_scale,
                height = height * monitor_scale,
            )

            rl.DrawText(rl.GetMonitorName(draw_index), rec.x + 10, rec.y + 10, 20, rl.BLUE)

            if draw_index == current_monitor_index:
                rl.DrawRectangleLinesEx(rec, 5.0, rl.RED)
                rl.DrawText(current_label, rec.x + 10, rec.y + 40, 20, rl.RED)
                let window_position = rl.GetWindowPosition()
                rl.DrawRectangleV(
                    rl.Vector2(
                        x = (window_position.x + monitor_offset_x) * monitor_scale + 140.0,
                        y = window_position.y * monitor_scale + 80.0,
                    ),
                    rl.Vector2(
                        x = screen_width * monitor_scale,
                        y = screen_height * monitor_scale,
                    ),
                    rl.Fade(rl.GREEN, 0.5),
                )
            else:
                rl.DrawRectangleLinesEx(rec, 5.0, rl.GRAY)

            draw_index += 1

    return 0