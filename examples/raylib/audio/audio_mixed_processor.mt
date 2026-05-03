module examples.raylib.audio.audio_mixed_processor

import std.c.libm as libm
import std.c.raylib as rl

const average_volume_size: i32 = 400
const screen_width: i32 = 800
const screen_height: i32 = 450
const music_path: cstr = c"../resources/country.mp3"
const sound_path: cstr = c"../resources/coin.wav"
const playing_text: cstr = c"MUSIC SHOULD BE PLAYING!"
const exponent_format: cstr = c"EXPONENT = %.2f"
const sound_text: cstr = c"PRESS SPACE TO PLAY OTHER SOUND"
const controls_text: cstr = c"USE LEFT AND RIGHT ARROWS TO ALTER DISTORTION"
const window_title: cstr = c"raylib [audio] example - mixed processor"

var exponent: f32 = 1.0
var average_volume: array[f32, 400]


def void_ptr_to_f32(value: ptr[void]) -> ptr[f32]:
    unsafe:
        return ptr[f32]<-value


def signed_power(value: f32) -> f32:
    var sign: f32 = 1.0
    if value < 0.0:
        sign = -1.0
    return libm.powf(libm.fabsf(value), exponent) * sign


def process_audio(buffer: ptr[void], frames: u32) -> void:
    let samples = void_ptr_to_f32(buffer)
    let frame_count = i32<-frames
    let frames_f = f32<-frame_count
    var average: f32 = 0.0

    unsafe:
        for frame in range(0, frame_count):
            let left_index = frame * 2
            let right_index = left_index + 1
            let left_sample = signed_power(read(samples + left_index))
            let right_sample = signed_power(read(samples + right_index))

            read(samples + left_index) = left_sample
            read(samples + right_index) = right_sample

            average += libm.fabsf(left_sample) / frames_f
            average += libm.fabsf(right_sample) / frames_f

    for index in range(0, average_volume_size - 1):
        average_volume[index] = average_volume[index + 1]

    average_volume[average_volume_size - 1] = average


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.InitAudioDevice()
    defer rl.CloseAudioDevice()

    rl.AttachAudioMixedProcessor(process_audio)
    defer rl.DetachAudioMixedProcessor(process_audio)

    let music = rl.LoadMusicStream(music_path)
    defer rl.UnloadMusicStream(music)

    let sound = rl.LoadSound(sound_path)
    defer rl.UnloadSound(sound)

    rl.PlayMusicStream(music)
    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateMusicStream(music)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
            exponent -= 0.05
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            exponent += 0.05

        if exponent <= 0.5:
            exponent = 0.5
        if exponent >= 3.0:
            exponent = 3.0

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            rl.PlaySound(sound)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawText(playing_text, 255, 150, 20, rl.LIGHTGRAY)
        rl.DrawText(rl.TextFormat(exponent_format, exponent), 215, 180, 20, rl.LIGHTGRAY)

        rl.DrawRectangle(199, 199, 402, 34, rl.LIGHTGRAY)
        for index in range(0, average_volume_size):
            rl.DrawLine(201 + index, 232 - i32<-(average_volume[index] * 32.0), 201 + index, 232, rl.MAROON)
        rl.DrawRectangleLines(199, 199, 402, 34, rl.GRAY)

        rl.DrawText(sound_text, 200, 250, 20, rl.LIGHTGRAY)
        rl.DrawText(controls_text, 140, 280, 20, rl.LIGHTGRAY)

    return 0
