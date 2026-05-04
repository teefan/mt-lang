module examples.raylib.audio.audio_stream_callback

import std.c.raylib as rl
import std.raylib.math as rm

enum WaveType: i32
    SINE = 0
    SQUARE = 1
    TRIANGLE = 2
    SAWTOOTH = 3

const buffer_size: i32 = 4096
const sample_rate: i32 = 44100
const visible_sample_count: i32 = sample_rate / 100
const screen_width: i32 = 800
const screen_height: i32 = 450
const frequency_format: cstr = c"frequency: %i"
const wave_type_format: cstr = c"wave kind: %s"
const frequency_text: cstr = c"Up/down to change frequency"
const wave_type_text: cstr = c"Left/right to change wave type"
const window_title: cstr = c"raylib [audio] example - stream callback"

var wave_frequency: i32 = 440
var new_wave_frequency: i32 = 440
var wave_index: i32 = 0
var buffer: array[f32, 44100]


def void_ptr_to_f32(value: ptr[void]) -> ptr[f32]:
    unsafe:
        return ptr[f32]<-value


def advance_wave_state(wavelength: i32) -> void:
    wave_index += 1
    if wave_index >= wavelength:
        wave_frequency = new_wave_frequency
        wave_index = 0


def save_wave_samples(samples: ptr[f32], frame_count: i32) -> void:
    unsafe:
        for index in 0..sample_rate - frame_count:
            buffer[index] = buffer[index + frame_count]

        for index in 0..frame_count:
            buffer[sample_rate - frame_count + index] = read(samples + index)


def sine_callback(frames_out: ptr[void], frame_count: u32) -> void:
    let samples = void_ptr_to_f32(frames_out)
    let count = i32<-frame_count
    let wavelength = sample_rate / wave_frequency

    unsafe:
        for index in 0..count:
            read(samples + index) = rm.sin(2.0 * rl.PI * f32<-wave_index / f32<-wavelength)
            advance_wave_state(wavelength)

    save_wave_samples(samples, count)


def square_callback(frames_out: ptr[void], frame_count: u32) -> void:
    let samples = void_ptr_to_f32(frames_out)
    let count = i32<-frame_count
    let wavelength = sample_rate / wave_frequency
    let half_wavelength = wavelength / 2

    unsafe:
        for index in 0..count:
            read(samples + index) = if wave_index < half_wavelength: 1.0 else: -1.0
            advance_wave_state(wavelength)

    save_wave_samples(samples, count)


def triangle_callback(frames_out: ptr[void], frame_count: u32) -> void:
    let samples = void_ptr_to_f32(frames_out)
    let count = i32<-frame_count
    let wavelength = sample_rate / wave_frequency
    let half_wavelength = wavelength / 2

    unsafe:
        for index in 0..count:
            var sample: f32 = 0.0
            if wave_index < half_wavelength:
                sample = -1.0 + 2.0 * f32<-wave_index / f32<-half_wavelength
            else:
                sample = 1.0 - 2.0 * f32<-(wave_index - half_wavelength) / f32<-half_wavelength

            read(samples + index) = sample
            advance_wave_state(wavelength)

    save_wave_samples(samples, count)


def sawtooth_callback(frames_out: ptr[void], frame_count: u32) -> void:
    let samples = void_ptr_to_f32(frames_out)
    let count = i32<-frame_count
    let wavelength = sample_rate / wave_frequency

    unsafe:
        for index in 0..count:
            read(samples + index) = -1.0 + 2.0 * f32<-wave_index / f32<-wavelength
            advance_wave_state(wavelength)

    save_wave_samples(samples, count)


def preview_sample_index(index: i32) -> i32:
    let base_index = sample_rate - visible_sample_count
    let sample_index = base_index + index * visible_sample_count / screen_width
    if sample_index >= sample_rate:
        return sample_rate - 1
    return sample_index


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.InitAudioDevice()
    defer rl.CloseAudioDevice()

    rl.SetAudioStreamBufferSizeDefault(buffer_size)

    let stream = rl.LoadAudioStream(sample_rate, 32, 1)
    defer rl.UnloadAudioStream(stream)

    let wave_callbacks = array[fn(arg0: ptr[void], arg1: u32) -> void, 4](
        sine_callback,
        square_callback,
        triangle_callback,
        sawtooth_callback,
    )
    let wave_type_names = array[cstr, 4](c"sine", c"square", c"triangle", c"sawtooth")

    var wave_type = WaveType.SINE
    rl.PlayAudioStream(stream)
    rl.SetAudioStreamCallback(stream, wave_callbacks[i32<-wave_type])

    rl.SetTargetFPS(30)

    while not rl.WindowShouldClose():
        if rl.IsKeyDown(rl.KeyboardKey.KEY_UP):
            new_wave_frequency += 10
            if new_wave_frequency > 12500:
                new_wave_frequency = 12500

        if rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN):
            new_wave_frequency -= 10
            if new_wave_frequency < 20:
                new_wave_frequency = 20

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
            if wave_type == WaveType.SINE:
                wave_type = WaveType.SAWTOOTH
            elif wave_type == WaveType.SQUARE:
                wave_type = WaveType.SINE
            elif wave_type == WaveType.TRIANGLE:
                wave_type = WaveType.SQUARE
            else:
                wave_type = WaveType.TRIANGLE

            rl.SetAudioStreamCallback(stream, wave_callbacks[i32<-wave_type])

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            if wave_type == WaveType.SINE:
                wave_type = WaveType.SQUARE
            elif wave_type == WaveType.SQUARE:
                wave_type = WaveType.TRIANGLE
            elif wave_type == WaveType.TRIANGLE:
                wave_type = WaveType.SAWTOOTH
            else:
                wave_type = WaveType.SINE

            rl.SetAudioStreamCallback(stream, wave_callbacks[i32<-wave_type])

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawText(rl.TextFormat(frequency_format, new_wave_frequency), screen_width - 220, 10, 20, rl.RED)
        rl.DrawText(rl.TextFormat(wave_type_format, wave_type_names[i32<-wave_type]), screen_width - 220, 30, 20, rl.RED)
        rl.DrawText(frequency_text, 10, 10, 20, rl.DARKGRAY)
        rl.DrawText(wave_type_text, 10, 30, 20, rl.DARKGRAY)

        for index in 0..screen_width:
            let start_sample = preview_sample_index(index)
            let end_sample = preview_sample_index(index + 1)
            let start_pos = rl.Vector2(
                x = f32<-index,
                y = 250.0 - 50.0 * buffer[start_sample],
            )
            let end_pos = rl.Vector2(
                x = f32<-(index + 1),
                y = 250.0 - 50.0 * buffer[end_sample],
            )
            rl.DrawLineV(start_pos, end_pos, rl.RED)

    return 0
