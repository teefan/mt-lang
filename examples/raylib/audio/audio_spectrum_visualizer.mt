module examples.raylib.audio.audio_spectrum_visualizer

import std.c.libm as libm
import std.c.raylib as rl
import std.raylib.math as rm

struct FFTComplex:
    real: f32
    imaginary: f32

const glsl_version: i32 = 330
const mono: i32 = 1
const sample_rate: i32 = 44100
const fft_window_size: i32 = 1024
const buffer_size: i32 = 512
const per_sample_bit_depth: i32 = 32
const audio_stream_ring_buffer_size: i32 = fft_window_size * 2
const effective_sample_rate: f32 = f32<-sample_rate * 0.5
const window_time: f32 = f32<-fft_window_size / effective_sample_rate
const fft_history_len: i32 = 45
const min_decibels: f32 = -100.0
const max_decibels: f32 = -30.0
const inverse_decibel_range: f32 = 1.0 / (max_decibels - min_decibels)
const db_to_linear_scale: f32 = 20.0 / 2.302585092994046
const smoothing_time_constant: f32 = 0.8
const texture_height: i32 = 1
const fft_row: i32 = 0
const unused_channel: f32 = 0.0
const screen_width: i32 = 800
const screen_height: i32 = 450
const shader_path_format: cstr = c"../resources/shaders/glsl%i/fft.fs"
const resolution_uniform_name: cstr = c"iResolution"
const channel_uniform_name: cstr = c"iChannel0"
const wave_path: cstr = c"../resources/country.mp3"
const window_title: cstr = c"raylib [audio] example - spectrum visualizer"

var work_buffer: array[FFTComplex, 1024]
var prev_magnitudes: array[f32, 512]
var fft_history: array[array[f32, 512], 45]
var history_pos: i32 = 0
var tapback_pos: f32 = 0.01


def swap_fft_values(left: i32, right: i32) -> void:
    let temp = work_buffer[left]
    work_buffer[left] = work_buffer[right]
    work_buffer[right] = temp


def cooley_tukey_fft_slow() -> void:
    var j = 0
    for index in range(1, fft_window_size - 1):
        var bit = fft_window_size / 2
        while j >= bit:
            j -= bit
            bit /= 2
        j += bit
        if index < j:
            swap_fft_values(index, j)

    var length = 2
    while length <= fft_window_size:
        let angle = -2.0 * rl.PI / f32<-length
        let twiddle_unit = FFTComplex(real = rm.cos(angle), imaginary = rm.sin(angle))
        var offset = 0

        while offset < fft_window_size:
            var twiddle_current = FFTComplex(real = 1.0, imaginary = 0.0)
            for half_index in range(0, length / 2):
                let even = work_buffer[offset + half_index]
                let odd = work_buffer[offset + half_index + length / 2]
                let twiddled_odd = FFTComplex(
                    real = odd.real * twiddle_current.real - odd.imaginary * twiddle_current.imaginary,
                    imaginary = odd.real * twiddle_current.imaginary + odd.imaginary * twiddle_current.real,
                )

                work_buffer[offset + half_index] = FFTComplex(
                    real = even.real + twiddled_odd.real,
                    imaginary = even.imaginary + twiddled_odd.imaginary,
                )
                work_buffer[offset + half_index + length / 2] = FFTComplex(
                    real = even.real - twiddled_odd.real,
                    imaginary = even.imaginary - twiddled_odd.imaginary,
                )

                let next_real = twiddle_current.real * twiddle_unit.real - twiddle_current.imaginary * twiddle_unit.imaginary
                twiddle_current.imaginary = twiddle_current.real * twiddle_unit.imaginary + twiddle_current.imaginary * twiddle_unit.real
                twiddle_current.real = next_real

            offset += length

        length *= 2


def capture_frame(audio_samples: ptr[f32]) -> void:
    for index in range(0, fft_window_size):
        let x = (2.0 * rl.PI * f32<-index) / f32<-(fft_window_size - 1)
        let blackman_weight = 0.42 - 0.5 * rm.cos(x) + 0.08 * rm.cos(2.0 * x)
        unsafe:
            work_buffer[index].real = read(audio_samples + index) * blackman_weight
        work_buffer[index].imaginary = 0.0

    cooley_tukey_fft_slow()

    var smoothed_spectrum = zero[array[f32, 512]]()
    for bin in range(0, buffer_size):
        let re = work_buffer[bin].real
        let im = work_buffer[bin].imaginary
        let linear_magnitude = rm.sqrt(re * re + im * im) / f32<-fft_window_size
        let smoothed_magnitude = smoothing_time_constant * prev_magnitudes[bin] + (1.0 - smoothing_time_constant) * linear_magnitude
        prev_magnitudes[bin] = smoothed_magnitude

        let db_source = if smoothed_magnitude > 0.0000000000000000000000000000000000000001: smoothed_magnitude else: 0.0000000000000000000000000000000000000001
        let db = libm.logf(db_source) * db_to_linear_scale
        let normalized = (db - min_decibels) * inverse_decibel_range
        smoothed_spectrum[bin] = rm.clamp(normalized, 0.0, 1.0)

    for bin in range(0, buffer_size):
        fft_history[history_pos][bin] = smoothed_spectrum[bin]

    history_pos = (history_pos + 1) % fft_history_len


def render_frame(fft_image: ptr[rl.Image]) -> void:
    var frames_since_tapback = libm.floorf(tapback_pos / window_time)
    frames_since_tapback = rm.clamp(frames_since_tapback, 0.0, f32<-(fft_history_len - 1))

    var history_position = (history_pos - 1 - i32<-frames_since_tapback) % fft_history_len
    if history_position < 0:
        history_position += fft_history_len

    for bin in range(0, buffer_size):
        let amplitude = fft_history[history_position][bin]
        rl.ImageDrawPixel(
            fft_image,
            bin,
            fft_row,
            rl.ColorFromNormalized(rl.Vector4(x = amplitude, y = unused_channel, z = unused_channel, w = unused_channel)),
        )


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var fft_image = rl.GenImageColor(buffer_size, texture_height, rl.WHITE)
    defer rl.UnloadImage(fft_image)

    let fft_texture = rl.LoadTextureFromImage(fft_image)
    defer rl.UnloadTexture(fft_texture)

    let buffer_a = rl.LoadRenderTexture(screen_width, screen_height)
    defer rl.UnloadRenderTexture(buffer_a)

    var i_resolution = rl.Vector2(x = f32<-screen_width, y = f32<-screen_height)
    let shader = rl.LoadShader(null, rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    let i_resolution_location = rl.GetShaderLocation(shader, resolution_uniform_name)
    let i_channel0_location = rl.GetShaderLocation(shader, channel_uniform_name)
    rl.SetShaderValue(shader, i_resolution_location, ptr_of(ref_of(i_resolution)), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
    rl.SetShaderValueTexture(shader, i_channel0_location, fft_texture)

    rl.InitAudioDevice()
    defer rl.CloseAudioDevice()

    rl.SetAudioStreamBufferSizeDefault(audio_stream_ring_buffer_size)

    var wav = rl.LoadWave(wave_path)
    defer rl.UnloadWave(wav)
    rl.WaveFormat(ptr_of(ref_of(wav)), sample_rate, per_sample_bit_depth, mono)

    let wav_samples = rl.LoadWaveSamples(wav)
    defer rl.UnloadWaveSamples(wav_samples)

    let audio_stream = rl.LoadAudioStream(sample_rate, per_sample_bit_depth, mono)
    defer rl.UnloadAudioStream(audio_stream)
    rl.PlayAudioStream(audio_stream)

    var wav_cursor = 0
    let wav_frame_count = i32<-wav.frameCount
    var chunk_samples = zero[array[f32, 2048]]()
    var audio_samples = zero[array[f32, 1024]]()

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        while rl.IsAudioStreamProcessed(audio_stream):
            unsafe:
                for index in range(0, audio_stream_ring_buffer_size):
                    chunk_samples[index] = read(wav_samples + wav_cursor)
                    wav_cursor += 1
                    if wav_cursor >= wav_frame_count:
                        wav_cursor = 0

            rl.UpdateAudioStream(audio_stream, ptr_of(ref_of(chunk_samples[0])), audio_stream_ring_buffer_size)

            for index in range(0, fft_window_size):
                audio_samples[index] = (chunk_samples[index * 2] + chunk_samples[index * 2 + 1]) * 0.5

        capture_frame(ptr_of(ref_of(audio_samples[0])))
        render_frame(ptr_of(ref_of(fft_image)))
        rl.UpdateTexture(fft_texture, fft_image.data)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginShaderMode(shader)
        rl.SetShaderValueTexture(shader, i_channel0_location, fft_texture)
        rl.DrawTextureRec(
            buffer_a.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = f32<-screen_width, height = -f32<-screen_height),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE,
        )
        rl.EndShaderMode()

    return 0
