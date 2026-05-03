module examples.idiomatic.raylib.window_flags

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Window Flags")
    defer rl.close_window()

    var ball_position = rl.Vector2(
        x = 0.5 * rl.get_screen_width(),
        y = 0.5 * rl.get_screen_height(),
    )
    var ball_speed = rl.Vector2(x = 5.0, y = 4.0)
    let ball_radius: f32 = 20.0
    var frames_counter = 0

    let fullscreen_flag = rl.ConfigFlags.FLAG_FULLSCREEN_MODE
    let resizable_flag = rl.ConfigFlags.FLAG_WINDOW_RESIZABLE
    let undecorated_flag = rl.ConfigFlags.FLAG_WINDOW_UNDECORATED
    let hidden_flag = rl.ConfigFlags.FLAG_WINDOW_HIDDEN
    let minimized_flag = rl.ConfigFlags.FLAG_WINDOW_MINIMIZED
    let maximized_flag = rl.ConfigFlags.FLAG_WINDOW_MAXIMIZED
    let unfocused_flag = rl.ConfigFlags.FLAG_WINDOW_UNFOCUSED
    let topmost_flag = rl.ConfigFlags.FLAG_WINDOW_TOPMOST
    let always_run_flag = rl.ConfigFlags.FLAG_WINDOW_ALWAYS_RUN
    let transparent_flag = rl.ConfigFlags.FLAG_WINDOW_TRANSPARENT
    let highdpi_flag = rl.ConfigFlags.FLAG_WINDOW_HIGHDPI
    let borderless_flag = rl.ConfigFlags.FLAG_BORDERLESS_WINDOWED_MODE
    let vsync_flag = rl.ConfigFlags.FLAG_VSYNC_HINT
    let msaa_flag = rl.ConfigFlags.FLAG_MSAA_4X_HINT

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_F):
            rl.toggle_fullscreen()

        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            if rl.is_window_state(resizable_flag):
                rl.clear_window_state(resizable_flag)
            else:
                rl.set_window_state(resizable_flag)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_D):
            if rl.is_window_state(undecorated_flag):
                rl.clear_window_state(undecorated_flag)
            else:
                rl.set_window_state(undecorated_flag)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_H):
            if not rl.is_window_state(hidden_flag):
                rl.set_window_state(hidden_flag)
            frames_counter = 0

        if rl.is_window_state(hidden_flag):
            frames_counter += 1
            if frames_counter >= 240:
                rl.clear_window_state(hidden_flag)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_N):
            if not rl.is_window_state(minimized_flag):
                rl.minimize_window()
            frames_counter = 0

        if rl.is_window_state(minimized_flag):
            frames_counter += 1
            if frames_counter >= 240:
                rl.restore_window()
                frames_counter = 0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_M):
            if rl.is_window_state(maximized_flag):
                rl.restore_window()
            else:
                rl.maximize_window()

        if rl.is_key_pressed(rl.KeyboardKey.KEY_U):
            if rl.is_window_state(unfocused_flag):
                rl.clear_window_state(unfocused_flag)
            else:
                rl.set_window_state(unfocused_flag)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_T):
            if rl.is_window_state(topmost_flag):
                rl.clear_window_state(topmost_flag)
            else:
                rl.set_window_state(topmost_flag)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_A):
            if rl.is_window_state(always_run_flag):
                rl.clear_window_state(always_run_flag)
            else:
                rl.set_window_state(always_run_flag)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_V):
            if rl.is_window_state(vsync_flag):
                rl.clear_window_state(vsync_flag)
            else:
                rl.set_window_state(vsync_flag)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_B):
            rl.toggle_borderless_windowed()

        ball_position.x += ball_speed.x
        ball_position.y += ball_speed.y

        if ball_position.x >= rl.get_screen_width() - ball_radius or ball_position.x <= ball_radius:
            ball_speed.x *= -1.0
        if ball_position.y >= rl.get_screen_height() - ball_radius or ball_position.y <= ball_radius:
            ball_speed.y *= -1.0

        rl.begin_drawing()
        defer rl.end_drawing()

        if rl.is_window_state(transparent_flag):
            rl.clear_background(rl.BLANK)
        else:
            rl.clear_background(rl.RAYWHITE)

        rl.draw_circle_v(ball_position, ball_radius, rl.MAROON)
        rl.draw_rectangle_lines_ex(
            rl.Rectangle(
                x = 0,
                y = 0,
                width = rl.get_screen_width(),
                height = rl.get_screen_height(),
            ),
            4.0,
            rl.RAYWHITE,
        )
        rl.draw_circle_v(rl.get_mouse_position(), 10.0, rl.DARKBLUE)
        rl.draw_fps(10, 10)
        rl.draw_text("Following flags can be set after window creation:", 10, 60, 10, rl.GRAY)

        rl.draw_text(if rl.is_window_state(fullscreen_flag): "[F] FLAG_FULLSCREEN_MODE: on" else: "[F] FLAG_FULLSCREEN_MODE: off", 10, 80, 10, if rl.is_window_state(fullscreen_flag): rl.LIME else: rl.MAROON)
        rl.draw_text(if rl.is_window_state(resizable_flag): "[R] FLAG_WINDOW_RESIZABLE: on" else: "[R] FLAG_WINDOW_RESIZABLE: off", 10, 100, 10, if rl.is_window_state(resizable_flag): rl.LIME else: rl.MAROON)
        rl.draw_text(if rl.is_window_state(undecorated_flag): "[D] FLAG_WINDOW_UNDECORATED: on" else: "[D] FLAG_WINDOW_UNDECORATED: off", 10, 120, 10, if rl.is_window_state(undecorated_flag): rl.LIME else: rl.MAROON)
        rl.draw_text(if rl.is_window_state(hidden_flag): "[H] FLAG_WINDOW_HIDDEN: on" else: "[H] FLAG_WINDOW_HIDDEN: off (hides for 3 seconds)", 10, 140, 10, if rl.is_window_state(hidden_flag): rl.LIME else: rl.MAROON)
        rl.draw_text(if rl.is_window_state(minimized_flag): "[N] FLAG_WINDOW_MINIMIZED: on" else: "[N] FLAG_WINDOW_MINIMIZED: off (restores after 3 seconds)", 10, 160, 10, if rl.is_window_state(minimized_flag): rl.LIME else: rl.MAROON)
        rl.draw_text(if rl.is_window_state(maximized_flag): "[M] FLAG_WINDOW_MAXIMIZED: on" else: "[M] FLAG_WINDOW_MAXIMIZED: off", 10, 180, 10, if rl.is_window_state(maximized_flag): rl.LIME else: rl.MAROON)
        rl.draw_text(if rl.is_window_state(unfocused_flag): "[U] FLAG_WINDOW_UNFOCUSED: on" else: "[U] FLAG_WINDOW_UNFOCUSED: off", 10, 200, 10, if rl.is_window_state(unfocused_flag): rl.LIME else: rl.MAROON)
        rl.draw_text(if rl.is_window_state(topmost_flag): "[T] FLAG_WINDOW_TOPMOST: on" else: "[T] FLAG_WINDOW_TOPMOST: off", 10, 220, 10, if rl.is_window_state(topmost_flag): rl.LIME else: rl.MAROON)
        rl.draw_text(if rl.is_window_state(always_run_flag): "[A] FLAG_WINDOW_ALWAYS_RUN: on" else: "[A] FLAG_WINDOW_ALWAYS_RUN: off", 10, 240, 10, if rl.is_window_state(always_run_flag): rl.LIME else: rl.MAROON)
        rl.draw_text(if rl.is_window_state(vsync_flag): "[V] FLAG_VSYNC_HINT: on" else: "[V] FLAG_VSYNC_HINT: off", 10, 260, 10, if rl.is_window_state(vsync_flag): rl.LIME else: rl.MAROON)
        rl.draw_text(if rl.is_window_state(borderless_flag): "[B] FLAG_BORDERLESS_WINDOWED_MODE: on" else: "[B] FLAG_BORDERLESS_WINDOWED_MODE: off", 10, 280, 10, if rl.is_window_state(borderless_flag): rl.LIME else: rl.MAROON)

        rl.draw_text("Following flags can only be set before window creation:", 10, 320, 10, rl.GRAY)
        rl.draw_text(if rl.is_window_state(highdpi_flag): "FLAG_WINDOW_HIGHDPI: on" else: "FLAG_WINDOW_HIGHDPI: off", 10, 340, 10, if rl.is_window_state(highdpi_flag): rl.LIME else: rl.MAROON)
        rl.draw_text(if rl.is_window_state(transparent_flag): "FLAG_WINDOW_TRANSPARENT: on" else: "FLAG_WINDOW_TRANSPARENT: off", 10, 360, 10, if rl.is_window_state(transparent_flag): rl.LIME else: rl.MAROON)
        rl.draw_text(if rl.is_window_state(msaa_flag): "FLAG_MSAA_4X_HINT: on" else: "FLAG_MSAA_4X_HINT: off", 10, 380, 10, if rl.is_window_state(msaa_flag): rl.LIME else: rl.MAROON)

    return 0