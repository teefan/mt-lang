module examples.raylib.core.core_window_flags

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - window flags"
const runtime_flags_text: cstr = c"Following flags can be set after window creation:"
const startup_flags_text: cstr = c"Following flags can only be set before window creation:"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var ball_position = rl.Vector2(
        x = 0.5 * rl.GetScreenWidth(),
        y = 0.5 * rl.GetScreenHeight(),
    )
    var ball_speed = rl.Vector2(x = 5.0, y = 4.0)
    var ball_radius: f32 = 20.0
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
    let overlay_alpha: f32 = 0.5
    let outline_thickness: f32 = 4.0
    let cursor_radius: f32 = 10.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_F):
            rl.ToggleFullscreen()

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_R):
            if rl.IsWindowState(resizable_flag):
                rl.ClearWindowState(resizable_flag)
            else:
                rl.SetWindowState(resizable_flag)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_D):
            if rl.IsWindowState(undecorated_flag):
                rl.ClearWindowState(undecorated_flag)
            else:
                rl.SetWindowState(undecorated_flag)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_H):
            if not rl.IsWindowState(hidden_flag):
                rl.SetWindowState(hidden_flag)

            frames_counter = 0

        if rl.IsWindowState(hidden_flag):
            frames_counter += 1
            if frames_counter >= 240:
                rl.ClearWindowState(hidden_flag)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_N):
            if not rl.IsWindowState(minimized_flag):
                rl.MinimizeWindow()

            frames_counter = 0

        if rl.IsWindowState(minimized_flag):
            frames_counter += 1
            if frames_counter >= 240:
                rl.RestoreWindow()
                frames_counter = 0

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_M):
            if rl.IsWindowState(maximized_flag):
                rl.RestoreWindow()
            else:
                rl.MaximizeWindow()

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_U):
            if rl.IsWindowState(unfocused_flag):
                rl.ClearWindowState(unfocused_flag)
            else:
                rl.SetWindowState(unfocused_flag)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_T):
            if rl.IsWindowState(topmost_flag):
                rl.ClearWindowState(topmost_flag)
            else:
                rl.SetWindowState(topmost_flag)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_A):
            if rl.IsWindowState(always_run_flag):
                rl.ClearWindowState(always_run_flag)
            else:
                rl.SetWindowState(always_run_flag)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_V):
            if rl.IsWindowState(vsync_flag):
                rl.ClearWindowState(vsync_flag)
            else:
                rl.SetWindowState(vsync_flag)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_B):
            rl.ToggleBorderlessWindowed()

        ball_position.x += ball_speed.x
        ball_position.y += ball_speed.y

        if ball_position.x >= cast[f32](rl.GetScreenWidth()) - ball_radius or ball_position.x <= ball_radius:
            ball_speed.x *= -1.0
        if ball_position.y >= cast[f32](rl.GetScreenHeight()) - ball_radius or ball_position.y <= ball_radius:
            ball_speed.y *= -1.0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        if rl.IsWindowState(transparent_flag):
            rl.ClearBackground(rl.BLANK)
        else:
            rl.ClearBackground(rl.RAYWHITE)

        rl.DrawCircleV(ball_position, ball_radius, rl.MAROON)
        rl.DrawRectangleLinesEx(
            rl.Rectangle(
                x = 0.0,
                y = 0.0,
                width = cast[f32](rl.GetScreenWidth()),
                height = cast[f32](rl.GetScreenHeight()),
            ),
            outline_thickness,
            rl.RAYWHITE,
        )
        rl.DrawCircleV(rl.GetMousePosition(), cursor_radius, rl.DARKBLUE)
        rl.DrawFPS(10, 10)
        rl.DrawText(runtime_flags_text, 10, 60, 10, rl.GRAY)

        if rl.IsWindowState(fullscreen_flag):
            rl.DrawText(c"[F] FLAG_FULLSCREEN_MODE: on", 10, 80, 10, rl.LIME)
        else:
            rl.DrawText(c"[F] FLAG_FULLSCREEN_MODE: off", 10, 80, 10, rl.MAROON)
        if rl.IsWindowState(resizable_flag):
            rl.DrawText(c"[R] FLAG_WINDOW_RESIZABLE: on", 10, 100, 10, rl.LIME)
        else:
            rl.DrawText(c"[R] FLAG_WINDOW_RESIZABLE: off", 10, 100, 10, rl.MAROON)
        if rl.IsWindowState(undecorated_flag):
            rl.DrawText(c"[D] FLAG_WINDOW_UNDECORATED: on", 10, 120, 10, rl.LIME)
        else:
            rl.DrawText(c"[D] FLAG_WINDOW_UNDECORATED: off", 10, 120, 10, rl.MAROON)
        if rl.IsWindowState(hidden_flag):
            rl.DrawText(c"[H] FLAG_WINDOW_HIDDEN: on", 10, 140, 10, rl.LIME)
        else:
            rl.DrawText(c"[H] FLAG_WINDOW_HIDDEN: off (hides for 3 seconds)", 10, 140, 10, rl.MAROON)
        if rl.IsWindowState(minimized_flag):
            rl.DrawText(c"[N] FLAG_WINDOW_MINIMIZED: on", 10, 160, 10, rl.LIME)
        else:
            rl.DrawText(c"[N] FLAG_WINDOW_MINIMIZED: off (restores after 3 seconds)", 10, 160, 10, rl.MAROON)
        if rl.IsWindowState(maximized_flag):
            rl.DrawText(c"[M] FLAG_WINDOW_MAXIMIZED: on", 10, 180, 10, rl.LIME)
        else:
            rl.DrawText(c"[M] FLAG_WINDOW_MAXIMIZED: off", 10, 180, 10, rl.MAROON)
        if rl.IsWindowState(unfocused_flag):
            rl.DrawText(c"[U] FLAG_WINDOW_UNFOCUSED: on", 10, 200, 10, rl.LIME)
        else:
            rl.DrawText(c"[U] FLAG_WINDOW_UNFOCUSED: off", 10, 200, 10, rl.MAROON)
        if rl.IsWindowState(topmost_flag):
            rl.DrawText(c"[T] FLAG_WINDOW_TOPMOST: on", 10, 220, 10, rl.LIME)
        else:
            rl.DrawText(c"[T] FLAG_WINDOW_TOPMOST: off", 10, 220, 10, rl.MAROON)
        if rl.IsWindowState(always_run_flag):
            rl.DrawText(c"[A] FLAG_WINDOW_ALWAYS_RUN: on", 10, 240, 10, rl.LIME)
        else:
            rl.DrawText(c"[A] FLAG_WINDOW_ALWAYS_RUN: off", 10, 240, 10, rl.MAROON)
        if rl.IsWindowState(vsync_flag):
            rl.DrawText(c"[V] FLAG_VSYNC_HINT: on", 10, 260, 10, rl.LIME)
        else:
            rl.DrawText(c"[V] FLAG_VSYNC_HINT: off", 10, 260, 10, rl.MAROON)
        if rl.IsWindowState(borderless_flag):
            rl.DrawText(c"[B] FLAG_BORDERLESS_WINDOWED_MODE: on", 10, 280, 10, rl.LIME)
        else:
            rl.DrawText(c"[B] FLAG_BORDERLESS_WINDOWED_MODE: off", 10, 280, 10, rl.MAROON)

        rl.DrawText(startup_flags_text, 10, 320, 10, rl.GRAY)
        if rl.IsWindowState(highdpi_flag):
            rl.DrawText(c"FLAG_WINDOW_HIGHDPI: on", 10, 340, 10, rl.LIME)
        else:
            rl.DrawText(c"FLAG_WINDOW_HIGHDPI: off", 10, 340, 10, rl.MAROON)
        if rl.IsWindowState(transparent_flag):
            rl.DrawText(c"FLAG_WINDOW_TRANSPARENT: on", 10, 360, 10, rl.LIME)
        else:
            rl.DrawText(c"FLAG_WINDOW_TRANSPARENT: off", 10, 360, 10, rl.MAROON)
        if rl.IsWindowState(msaa_flag):
            rl.DrawText(c"FLAG_MSAA_4X_HINT: on", 10, 380, 10, rl.LIME)
        else:
            rl.DrawText(c"FLAG_MSAA_4X_HINT: off", 10, 380, 10, rl.MAROON)

    return 0
