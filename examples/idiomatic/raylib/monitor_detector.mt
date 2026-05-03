module examples.idiomatic.raylib.monitor_detector

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Monitor Detector")
    defer rl.close_window()

    var current_monitor_index = rl.get_current_monitor()

    rl.set_target_fps(60)

    while not rl.window_should_close():
        var max_width = 1
        var max_height = 1
        var monitor_offset_x = 0
        let monitor_count = rl.get_monitor_count()

        var index = 0
        while index < monitor_count:
            let position = rl.get_monitor_position(index)
            let width = rl.get_monitor_width(index)
            let height = rl.get_monitor_height(index)

            if position.x < monitor_offset_x:
                monitor_offset_x = -i32<-position.x

            let right_edge = i32<-position.x + width
            let bottom_edge = i32<-position.y + height
            if max_width < right_edge:
                max_width = right_edge
            if max_height < bottom_edge:
                max_height = bottom_edge

            index += 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER) and monitor_count > 1:
            current_monitor_index += 1
            if current_monitor_index == monitor_count:
                current_monitor_index = 0
            rl.set_window_monitor(current_monitor_index)
        else:
            current_monitor_index = rl.get_current_monitor()

        var monitor_scale: f32 = 0.6
        if max_height > max_width + monitor_offset_x:
            monitor_scale *= f32<-screen_height / max_height
        else:
            monitor_scale *= f32<-screen_width / (max_width + monitor_offset_x)

        let monitor_offset_x_f: f32 = monitor_offset_x

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("Press [Enter] to move window to next monitor available", 20, 20, 20, rl.DARKGRAY)
        rl.draw_rectangle_lines(20, 60, screen_width - 40, screen_height - 100, rl.DARKGRAY)

        var draw_index = 0
        while draw_index < monitor_count:
            let position = rl.get_monitor_position(draw_index)
            let width = rl.get_monitor_width(draw_index)
            let height = rl.get_monitor_height(draw_index)
            let rec = rl.Rectangle(
                x = (position.x + monitor_offset_x_f) * monitor_scale + 140.0,
                y = position.y * monitor_scale + 80.0,
                width = width * monitor_scale,
                height = height * monitor_scale,
            )
            let label_x = i32<-(rec.x + 10.0)
            let label_y = i32<-(rec.y + 10.0)
            let current_y = i32<-(rec.y + 40.0)

            rl.draw_text(rl.get_monitor_name(draw_index), label_x, label_y, 20, rl.BLUE)

            if draw_index == current_monitor_index:
                rl.draw_rectangle_lines_ex(rec, 5.0, rl.RED)
                rl.draw_text("CURRENT", label_x, current_y, 20, rl.RED)

                let window_position = rl.get_window_position()
                rl.draw_rectangle_v(
                    rl.Vector2(
                        x = (window_position.x + monitor_offset_x_f) * monitor_scale + 140.0,
                        y = window_position.y * monitor_scale + 80.0,
                    ),
                    rl.Vector2(
                        x = screen_width * monitor_scale,
                        y = screen_height * monitor_scale,
                    ),
                    rl.fade(rl.GREEN, 0.5),
                )
            else:
                rl.draw_rectangle_lines_ex(rec, 5.0, rl.GRAY)

            draw_index += 1

    return 0
