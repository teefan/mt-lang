module examples.raylib.core.core_screen_recording

import std.c.libm as math
import std.c.msf_gif as gif
import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - screen recording"
const gif_record_framerate: i32 = 5
const max_sinewave_points: i32 = 256


def half_screen_height() -> f32:
    return 0.5 * screen_height


def horizontal_step() -> f32:
    return f32<-rl.GetScreenWidth() / f32<-180


def sine_factor() -> f32:
    return (2.0 * rl.PI / 1.5)


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var gif_recording = false
    var gif_frame_counter = 0
    var gif_state = zero[gif.MsfGifState]()

    var circle_position = rl.Vector2(x = 0.0, y = half_screen_height())
    var time_counter: f32 = 0.0
    var sine_points = zero[array[rl.Vector2, 256]]()
    var point_index = 0
    while point_index < max_sinewave_points:
        sine_points[point_index].x = f32<-point_index * horizontal_step()
        sine_points[point_index].y = half_screen_height() + 150.0 * math.sinf(sine_factor() * (1.0 / 60.0) * f32<-point_index)
        point_index += 1

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        time_counter += rl.GetFrameTime()
        circle_position.x += horizontal_step()
        circle_position.y = half_screen_height() + 150.0 * math.sinf(sine_factor() * time_counter)
        if circle_position.x > screen_width:
            circle_position.x = 0.0
            circle_position.y = half_screen_height()
            time_counter = 0.0

        if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT_CONTROL) and rl.IsKeyPressed(rl.KeyboardKey.KEY_R):
            if gif_recording:
                gif_recording = false
                let result = gif.msf_gif_end(ptr_of(ref_of(gif_state)))
                rl.SaveFileData(rl.TextFormat(c"%s/screenrecording.gif", rl.GetApplicationDirectory()), result.data, i32<-result.dataSize)
                gif.msf_gif_free(result)
                rl.TraceLog(rl.TraceLogLevel.LOG_INFO, c"Finish animated GIF recording")
            else:
                gif_recording = true
                gif_frame_counter = 0
                gif.msf_gif_begin(ptr_of(ref_of(gif_state)), rl.GetRenderWidth(), rl.GetRenderHeight())
                rl.TraceLog(rl.TraceLogLevel.LOG_INFO, c"Start animated GIF recording")

        if gif_recording:
            gif_frame_counter += 1
            if gif_frame_counter > gif_record_framerate:
                let image_screen = rl.LoadImageFromScreen()
                unsafe:
                    gif.msf_gif_frame(
                        ptr_of(ref_of(gif_state)),
                        ptr[u8]<-image_screen.data,
                        i32<-((1.0 / 60.0) * gif_record_framerate) / 10,
                        16,
                        image_screen.width * 4,
                    )
                gif_frame_counter = 0
                rl.UnloadImage(image_screen)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        for index in 0..max_sinewave_points - 1:
            rl.DrawLineV(sine_points[index], sine_points[index + 1], rl.MAROON)
            rl.DrawCircleV(sine_points[index], 3.0, rl.MAROON)

        rl.DrawCircleV(circle_position, 30.0, rl.RED)
        rl.DrawFPS(10, 10)

    if gif_recording:
        let result = gif.msf_gif_end(ptr_of(ref_of(gif_state)))
        gif.msf_gif_free(result)

    return 0
