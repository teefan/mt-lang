module examples.raylib.core.core_custom_frame_control

import std.c.raylib as rl
import std.raylib.runtime as runtime

const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [core] example - custom frame control"
const instructions_text: cstr = c"Circle is moving at a constant 200 pixels/sec,\nindependently of the frame rate."
const pause_text: cstr = c"PRESS SPACE to PAUSE MOVEMENT"
const target_text: cstr = c"PRESS UP | DOWN to CHANGE TARGET FPS"
const custom_frame_control_env: cstr = c"MILK_TEA_RAYLIB_ENABLE_CUSTOM_FRAME_CONTROL"


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let use_custom_frame_control = runtime.env_flag(custom_frame_control_env)
    var previous_time = rl.GetTime()
    var current_time: double = 0.0
    var update_draw_time: double = 0.0
    var wait_time: double = 0.0
    var delta_time: float = 0.0

    var time_counter: float = 0.0
    var position: float = 0.0
    var pause = false
    var target_fps = 60

    if not use_custom_frame_control:
        rl.SetTargetFPS(target_fps)

    while not rl.WindowShouldClose():
        if use_custom_frame_control:
            rl.PollInputEvents()

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            pause = not pause

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_UP):
            target_fps += 20
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_DOWN):
            target_fps -= 20

        if target_fps < 0:
            target_fps = 0

        if not use_custom_frame_control:
            rl.SetTargetFPS(target_fps)

        if not pause:
            position += 200.0 * delta_time
            if position >= rl.GetScreenWidth():
                position = 0.0
            time_counter += delta_time

        rl.BeginDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        for column in 0..rl.GetScreenWidth() / 200:
            rl.DrawRectangle(200 * column, 0, 1, rl.GetScreenHeight(), rl.SKYBLUE)

        rl.DrawCircle(int<-position, rl.GetScreenHeight() / 2 - 25, 50.0, rl.RED)

        rl.DrawText(rl.TextFormat(c"%03.0f ms", time_counter * 1000.0), int<-position - 40, rl.GetScreenHeight() / 2 - 100, 20, rl.MAROON)
        rl.DrawText(rl.TextFormat(c"PosX: %03.0f", position), int<-position - 50, rl.GetScreenHeight() / 2 + 40, 20, rl.BLACK)

        rl.DrawText(instructions_text, 10, 10, 20, rl.DARKGRAY)
        rl.DrawText(pause_text, 10, rl.GetScreenHeight() - 60, 20, rl.GRAY)
        rl.DrawText(target_text, 10, rl.GetScreenHeight() - 30, 20, rl.GRAY)
        rl.DrawText(rl.TextFormat(c"TARGET FPS: %i", target_fps), rl.GetScreenWidth() - 220, 10, 20, rl.LIME)
        if delta_time != 0.0:
            rl.DrawText(rl.TextFormat(c"CURRENT FPS: %i", int<-(1.0 / delta_time)), rl.GetScreenWidth() - 220, 40, 20, rl.GREEN)

        rl.EndDrawing()

        if use_custom_frame_control:
            rl.SwapScreenBuffer()

        if use_custom_frame_control:
            current_time = rl.GetTime()
            update_draw_time = current_time - previous_time

            if target_fps > 0:
                wait_time = 1.0 / double<-target_fps - update_draw_time
                if wait_time > 0.0:
                    rl.WaitTime(wait_time)
                    current_time = rl.GetTime()
                    delta_time = float<-(current_time - previous_time)
                else:
                    delta_time = float<-update_draw_time
            else:
                delta_time = float<-update_draw_time

            previous_time = current_time
        else:
            delta_time = rl.GetFrameTime()

    return 0
