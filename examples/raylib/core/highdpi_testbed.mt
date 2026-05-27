import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GRID_SPACING: int = 40


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_WINDOW_RESIZABLE | rl.ConfigFlags.FLAG_WINDOW_HIGHDPI)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - highdpi testbed")
    defer rl.close_window()

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse_pos = rl.get_mouse_position()
        let current_monitor = rl.get_current_monitor()
        let scale_dpi = rl.get_window_scale_dpi()
        let window_pos = rl.get_window_position()

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            rl.toggle_borderless_windowed()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_F):
            rl.toggle_fullscreen()

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        var h = 0
        while h < (rl.get_screen_height() / GRID_SPACING) + 1:
            rl.draw_text(f"#{h * GRID_SPACING}", 4, h * GRID_SPACING - 4, 10, rl.GRAY)
            rl.draw_line(24, h * GRID_SPACING, rl.get_screen_width(), h * GRID_SPACING, rl.LIGHTGRAY)
            h += 1

        var v = 0
        while v < (rl.get_screen_width() / GRID_SPACING) + 1:
            rl.draw_text(f"#{v * GRID_SPACING}", v * GRID_SPACING - 10, 4, 10, rl.GRAY)
            rl.draw_line(v * GRID_SPACING, 20, v * GRID_SPACING, rl.get_screen_height(), rl.LIGHTGRAY)
            v += 1

        rl.draw_text(
            f"CURRENT MONITOR: #{current_monitor + 1}/#{rl.get_monitor_count()} (#{rl.get_monitor_width(current_monitor)}x#{rl.get_monitor_height(current_monitor)})",
            50,
            50,
            20,
            rl.DARKGRAY,
        )
        rl.draw_text(f"WINDOW POSITION: #{int<-window_pos.x}x#{int<-window_pos.y}", 50, 90, 20, rl.DARKGRAY)
        rl.draw_text(f"SCREEN SIZE: #{rl.get_screen_width()}x#{rl.get_screen_height()}", 50, 130, 20, rl.DARKGRAY)
        rl.draw_text(f"RENDER SIZE: #{rl.get_render_width()}x#{rl.get_render_height()}", 50, 170, 20, rl.DARKGRAY)
        rl.draw_text(f"SCALE FACTOR: #{scale_dpi.x}x#{scale_dpi.y}", 50, 210, 20, rl.GRAY)

        rl.draw_rectangle(0, 0, 30, 60, rl.RED)
        rl.draw_rectangle(rl.get_screen_width() - 30, rl.get_screen_height() - 60, 30, 60, rl.BLUE)

        rl.draw_circle_v(mouse_pos, 20.0, rl.MAROON)
        rl.draw_rectangle_rec(rl.Rectangle(x = mouse_pos.x - 25.0, y = mouse_pos.y, width = 50.0, height = 2.0), rl.BLACK)
        rl.draw_rectangle_rec(rl.Rectangle(x = mouse_pos.x, y = mouse_pos.y - 25.0, width = 2.0, height = 50.0), rl.BLACK)

        var label_y = (int<-mouse_pos.y) + 30
        if mouse_pos.y > (float<-rl.get_screen_height()) - 60.0:
            label_y = (int<-mouse_pos.y) - 46

        rl.draw_text(f"[#{rl.get_mouse_x()},#{rl.get_mouse_y()}]", int<-mouse_pos.x - 44, label_y, 20, rl.BLACK)
        rl.end_drawing()

    return 0
