module examples.raylib.audio.audio_raw_stream

import std.c.raylib as rl
import std.raylib.math as rm

const buffer_size: i32 = 4096
const sample_rate: i32 = 44100
const screen_width: i32 = 800
const screen_height: i32 = 450
const frequency_format: cstr = c"sine frequency: %i"
const pan_format: cstr = c"pan: %.2f"
const frequency_text: cstr = c"Up/down to change frequency"
const pan_text: cstr = c"Left/right to pan"
const window_title: cstr = c"raylib [audio] example - raw stream"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.InitAudioDevice()
    defer rl.CloseAudioDevice()

    rl.SetAudioStreamBufferSizeDefault(buffer_size)
    var buffer = zero[array[f32, 4096]]

    let stream = rl.LoadAudioStream(sample_rate, 32, 1)
    defer rl.UnloadAudioStream(stream)

    var pan: f32 = 0.0
    rl.SetAudioStreamPan(stream, pan)
    rl.PlayAudioStream(stream)

    var sine_frequency = 440
    var new_sine_frequency = 440
    var sine_index = 0
    var sine_start_time: f64 = 0.0

    rl.SetTargetFPS(30)

    while not rl.WindowShouldClose():
        if rl.IsKeyDown(rl.KeyboardKey.KEY_UP):
            new_sine_frequency += 10
            if new_sine_frequency > 12500:
                new_sine_frequency = 12500

        if rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN):
            new_sine_frequency -= 10
            if new_sine_frequency < 20:
                new_sine_frequency = 20

        if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT):
            pan = rm.clamp(pan - 0.01, -1.0, 1.0)
            rl.SetAudioStreamPan(stream, pan)

        if rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT):
            pan = rm.clamp(pan + 0.01, -1.0, 1.0)
            rl.SetAudioStreamPan(stream, pan)

        if rl.IsAudioStreamProcessed(stream):
            for index in 0..buffer_size:
                let wavelength = sample_rate / sine_frequency
                let phase = 2.0 * rl.PI * f32<-sine_index / f32<-wavelength
                buffer[index] = rm.sin(phase)
                sine_index += 1

                if sine_index >= wavelength:
                    sine_frequency = new_sine_frequency
                    sine_index = 0
                    sine_start_time = rl.GetTime()

            rl.UpdateAudioStream(stream, ptr_of(buffer[0]), buffer_size)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawText(rl.TextFormat(frequency_format, sine_frequency), screen_width - 220, 10, 20, rl.RED)
        rl.DrawText(rl.TextFormat(pan_format, pan), screen_width - 220, 30, 20, rl.RED)
        rl.DrawText(frequency_text, 10, 10, 20, rl.DARKGRAY)
        rl.DrawText(pan_text, 10, 30, 20, rl.DARKGRAY)

        let window_start = i32<-((rl.GetTime() - sine_start_time) * f64<-sample_rate)
        let window_size = i32<-(0.1 * f32<-sample_rate)
        let wavelength = sample_rate / sine_frequency

        for index in 0..screen_width:
            let t0 = window_start + index * window_size / screen_width
            let t1 = window_start + (index + 1) * window_size / screen_width
            let start_pos = rl.Vector2(
                x = f32<-index,
                y = 250.0 + 50.0 * rm.sin(2.0 * rl.PI * f32<-t0 / f32<-wavelength),
            )
            let end_pos = rl.Vector2(
                x = f32<-(index + 1),
                y = 250.0 + 50.0 * rm.sin(2.0 * rl.PI * f32<-t1 / f32<-wavelength),
            )
            rl.DrawLineV(start_pos, end_pos, rl.RED)

    return 0
