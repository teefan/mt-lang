import std.raylib as rl
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - monitor detector")
    defer rl.close_window()

    var current_monitor_index = rl.get_current_monitor()

    rl.set_target_fps(60)

    while not rl.window_should_close():
        var max_width = 1
        var max_height = 1
        var monitor_offset_x = 0

        let monitor_count = rl.get_monitor_count()
        var monitor_index = 0
        while monitor_index < monitor_count:
            let monitor_position = rl.get_monitor_position(monitor_index)
            if monitor_position.x < float<-monitor_offset_x:
                monitor_offset_x = -(int<-monitor_position.x)

            let width = int<-monitor_position.x + rl.get_monitor_width(monitor_index)
            let height = int<-monitor_position.y + rl.get_monitor_height(monitor_index)
            if max_width < width:
                max_width = width
            if max_height < height:
                max_height = height

            monitor_index += 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER) and monitor_count > 1:
            current_monitor_index += 1
            if current_monitor_index == monitor_count:
                current_monitor_index = 0

            rl.set_window_monitor(current_monitor_index)
        else:
            current_monitor_index = rl.get_current_monitor()

        var monitor_scale: float = 0.6
        if max_height > (max_width + monitor_offset_x):
            monitor_scale *= (float<-SCREEN_HEIGHT) / (float<-max_height)
        else:
            monitor_scale *= (float<-SCREEN_WIDTH) / (float<-(max_width + monitor_offset_x))

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text("Press [Enter] to move window to next monitor available", 20, 20, 20, rl.DARKGRAY)
        rl.draw_rectangle_lines(20, 60, SCREEN_WIDTH - 40, SCREEN_HEIGHT - 100, rl.DARKGRAY)

        monitor_index = 0
        while monitor_index < monitor_count:
            let monitor_position = rl.get_monitor_position(monitor_index)
            let monitor_width = rl.get_monitor_width(monitor_index)
            let monitor_height = rl.get_monitor_height(monitor_index)
            let monitor_name = text.cstr_as_str(rl.get_monitor_name(monitor_index))
            let physical_width = rl.get_monitor_physical_width(monitor_index)
            let physical_height = rl.get_monitor_physical_height(monitor_index)
            let refresh_rate = rl.get_monitor_refresh_rate(monitor_index)

            let rec = rl.Rectangle(
                x = (monitor_position.x + (float<-monitor_offset_x)) * monitor_scale + 140.0,
                y = monitor_position.y * monitor_scale + 80.0,
                width = (float<-monitor_width) * monitor_scale,
                height = (float<-monitor_height) * monitor_scale,
            )

            let heading_y = (int<-rec.y) + int<-(100.0 * monitor_scale)
            let info_y = (int<-rec.y) + int<-(200.0 * monitor_scale)
            let info_size = int<-(120.0 * monitor_scale)

            rl.draw_text(f"[#{monitor_index}] #{monitor_name}", (int<-rec.x) + 10, heading_y, info_size, rl.BLUE)
            rl.draw_text(f"Resolution: [#{monitor_width}px x #{monitor_height}px]", (int<-rec.x) + 10, info_y, info_size, rl.DARKGRAY)
            rl.draw_text(f"RefreshRate: [#{refresh_rate}hz]", (int<-rec.x) + 10, info_y + info_size + 4, info_size, rl.DARKGRAY)
            rl.draw_text(f"Physical Size: [#{physical_width}mm x #{physical_height}mm]", (int<-rec.x) + 10, info_y + (info_size + 4) * 2, info_size, rl.DARKGRAY)
            rl.draw_text(f"Position: #{int<-monitor_position.x} x #{int<-monitor_position.y}", (int<-rec.x) + 10, info_y + (info_size + 4) * 3, info_size, rl.DARKGRAY)

            if monitor_index == current_monitor_index:
                rl.draw_rectangle_lines_ex(rec, 5.0, rl.RED)
                let window_origin = rl.get_window_position()
                let window_position = rl.Vector2(
                    x = (window_origin.x + (float<-monitor_offset_x)) * monitor_scale + 140.0,
                    y = window_origin.y * monitor_scale + 80.0,
                )
                rl.draw_rectangle_v(
                    window_position,
                    rl.Vector2(x = (float<-SCREEN_WIDTH) * monitor_scale, y = (float<-SCREEN_HEIGHT) * monitor_scale),
                    rl.fade(rl.GREEN, 0.5),
                )
            else:
                rl.draw_rectangle_lines_ex(rec, 5.0, rl.GRAY)

            monitor_index += 1

        rl.end_drawing()

    return 0
