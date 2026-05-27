import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const AUTO_RESTORE_FRAMES: int = 240
const BALL_RADIUS: float = 20.0


function toggle_window_flag(flag: rl.ConfigFlags) -> void:
    if rl.is_window_state(flag):
        rl.clear_window_state(flag)
    else:
        rl.set_window_state(flag)


function draw_toggle_flag_line(key_label: str, flag_label: str, flag: rl.ConfigFlags, y: int, off_text: str) -> void:
    if rl.is_window_state(flag):
        rl.draw_text(f"[#{key_label}] #{flag_label}: on", 10, y, 10, rl.LIME)
    else:
        rl.draw_text(f"[#{key_label}] #{flag_label}: #{off_text}", 10, y, 10, rl.MAROON)


function draw_static_flag_line(flag_label: str, flag: rl.ConfigFlags, y: int) -> void:
    if rl.is_window_state(flag):
        rl.draw_text(f"#{flag_label}: on", 10, y, 10, rl.LIME)
    else:
        rl.draw_text(f"#{flag_label}: off", 10, y, 10, rl.MAROON)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - window flags")
    defer rl.close_window()

    var ball_position = rl.Vector2(x = (float<-rl.get_screen_width()) / 2.0, y = (float<-rl.get_screen_height()) / 2.0)
    var ball_speed = rl.Vector2(x = 5.0, y = 4.0)

    var frames_counter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_F):
            rl.toggle_fullscreen()

        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            toggle_window_flag(rl.ConfigFlags.FLAG_WINDOW_RESIZABLE)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_D):
            toggle_window_flag(rl.ConfigFlags.FLAG_WINDOW_UNDECORATED)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_U):
            toggle_window_flag(rl.ConfigFlags.FLAG_WINDOW_UNFOCUSED)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_T):
            toggle_window_flag(rl.ConfigFlags.FLAG_WINDOW_TOPMOST)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_A):
            toggle_window_flag(rl.ConfigFlags.FLAG_WINDOW_ALWAYS_RUN)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_V):
            toggle_window_flag(rl.ConfigFlags.FLAG_VSYNC_HINT)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_B):
            rl.toggle_borderless_windowed()

        if rl.is_key_pressed(rl.KeyboardKey.KEY_H):
            if not rl.is_window_state(rl.ConfigFlags.FLAG_WINDOW_HIDDEN):
                rl.set_window_state(rl.ConfigFlags.FLAG_WINDOW_HIDDEN)

            frames_counter = 0

        if rl.is_window_state(rl.ConfigFlags.FLAG_WINDOW_HIDDEN):
            frames_counter += 1
            if frames_counter >= AUTO_RESTORE_FRAMES:
                rl.clear_window_state(rl.ConfigFlags.FLAG_WINDOW_HIDDEN)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_N):
            if not rl.is_window_state(rl.ConfigFlags.FLAG_WINDOW_MINIMIZED):
                rl.minimize_window()

            frames_counter = 0

        if rl.is_window_state(rl.ConfigFlags.FLAG_WINDOW_MINIMIZED):
            frames_counter += 1
            if frames_counter >= AUTO_RESTORE_FRAMES:
                rl.restore_window()
                frames_counter = 0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_M):
            if rl.is_window_state(rl.ConfigFlags.FLAG_WINDOW_MAXIMIZED):
                rl.restore_window()
            else:
                rl.maximize_window()

        ball_position.x += ball_speed.x
        ball_position.y += ball_speed.y

        if ball_position.x >= (float<-rl.get_screen_width()) - BALL_RADIUS or ball_position.x <= BALL_RADIUS:
            ball_speed.x *= -1.0
        if ball_position.y >= (float<-rl.get_screen_height()) - BALL_RADIUS or ball_position.y <= BALL_RADIUS:
            ball_speed.y *= -1.0

        rl.begin_drawing()

        if rl.is_window_state(rl.ConfigFlags.FLAG_WINDOW_TRANSPARENT):
            rl.clear_background(rl.BLANK)
        else:
            rl.clear_background(rl.RAYWHITE)

        rl.draw_circle_v(ball_position, BALL_RADIUS, rl.MAROON)
        rl.draw_rectangle_lines_ex(
            rl.Rectangle(x = 0.0, y = 0.0, width = float<-rl.get_screen_width(), height = float<-rl.get_screen_height()),
            4.0,
            rl.RAYWHITE,
        )
        rl.draw_circle_v(rl.get_mouse_position(), 10.0, rl.DARKBLUE)
        rl.draw_fps(10, 10)

        rl.draw_text(f"Screen Size: [#{rl.get_screen_width()}, #{rl.get_screen_height()}]", 10, 40, 10, rl.GREEN)

        rl.draw_text("Following flags can be set after window creation:", 10, 60, 10, rl.GRAY)
        draw_toggle_flag_line("F", "FLAG_FULLSCREEN_MODE", rl.ConfigFlags.FLAG_FULLSCREEN_MODE, 80, "off")
        draw_toggle_flag_line("R", "FLAG_WINDOW_RESIZABLE", rl.ConfigFlags.FLAG_WINDOW_RESIZABLE, 100, "off")
        draw_toggle_flag_line("D", "FLAG_WINDOW_UNDECORATED", rl.ConfigFlags.FLAG_WINDOW_UNDECORATED, 120, "off")
        draw_toggle_flag_line("H", "FLAG_WINDOW_HIDDEN", rl.ConfigFlags.FLAG_WINDOW_HIDDEN, 140, "off (hides for 3 seconds)")
        draw_toggle_flag_line("N", "FLAG_WINDOW_MINIMIZED", rl.ConfigFlags.FLAG_WINDOW_MINIMIZED, 160, "off (restores after 3 seconds)")
        draw_toggle_flag_line("M", "FLAG_WINDOW_MAXIMIZED", rl.ConfigFlags.FLAG_WINDOW_MAXIMIZED, 180, "off")
        draw_toggle_flag_line("U", "FLAG_WINDOW_UNFOCUSED", rl.ConfigFlags.FLAG_WINDOW_UNFOCUSED, 200, "off")
        draw_toggle_flag_line("T", "FLAG_WINDOW_TOPMOST", rl.ConfigFlags.FLAG_WINDOW_TOPMOST, 220, "off")
        draw_toggle_flag_line("A", "FLAG_WINDOW_ALWAYS_RUN", rl.ConfigFlags.FLAG_WINDOW_ALWAYS_RUN, 240, "off")
        draw_toggle_flag_line("V", "FLAG_VSYNC_HINT", rl.ConfigFlags.FLAG_VSYNC_HINT, 260, "off")
        draw_toggle_flag_line("B", "FLAG_BORDERLESS_WINDOWED_MODE", rl.ConfigFlags.FLAG_BORDERLESS_WINDOWED_MODE, 280, "off")

        rl.draw_text("Following flags can only be set before window creation:", 10, 320, 10, rl.GRAY)
        draw_static_flag_line("FLAG_WINDOW_HIGHDPI", rl.ConfigFlags.FLAG_WINDOW_HIGHDPI, 340)
        draw_static_flag_line("FLAG_WINDOW_TRANSPARENT", rl.ConfigFlags.FLAG_WINDOW_TRANSPARENT, 360)
        draw_static_flag_line("FLAG_MSAA_4X_HINT", rl.ConfigFlags.FLAG_MSAA_4X_HINT, 380)

        rl.end_drawing()

    return 0
