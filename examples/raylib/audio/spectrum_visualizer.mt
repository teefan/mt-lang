import std.math as math
import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330
const MONO: int = 1
const SAMPLE_RATE: int = 44100
const FFT_WINDOW_SIZE: int = 1024
const BUFFER_SIZE: int = 512
const PER_SAMPLE_BIT_DEPTH: int = 16
const AUDIO_STREAM_RING_BUFFER_SIZE: int = FFT_WINDOW_SIZE * 2
const WINDOW_TIME: double = 1024.0 / 22050.0
const MIN_DECIBELS: float = -100.0
const MAX_DECIBELS: float = -30.0
const INVERSE_DECIBEL_RANGE: float = 1.0 / (MAX_DECIBELS - MIN_DECIBELS)
const DB_TO_LINEAR_SCALE: float = 20.0 / 2.302585092994046
const SMOOTHING_TIME_CONSTANT: float = 0.8
const TEXTURE_HEIGHT: int = 1
const FFT_ROW: int = 0
const UNUSED_CHANNEL: float = 0.0
const FFT_HISTORY_LEN: int = 45

struct FFTComplex:
    real: float
    imaginary: float

var fft_spectrum: array[FFTComplex, FFT_WINDOW_SIZE] = zero[array[FFTComplex, FFT_WINDOW_SIZE]]
var fft_work_buffer: array[FFTComplex, FFT_WINDOW_SIZE] = zero[array[FFTComplex, FFT_WINDOW_SIZE]]
var fft_prev_magnitudes: array[float, BUFFER_SIZE] = zero[array[float, BUFFER_SIZE]]
var fft_history: array[
    array[float, BUFFER_SIZE],
    FFT_HISTORY_LEN
] = zero[array[array[float, BUFFER_SIZE], FFT_HISTORY_LEN]]
var fft_history_pos: int = 0
var fft_last_fft_time: double = 0.0
var fft_tapback_pos: float = 0.01


function cooley_tukey_fft_slow(n: int) -> void:
    var j = 0
    var index = 1
    while index < n - 1:
        var bit = n >> 1
        while j >= bit:
            j -= bit
            bit >>= 1
        j += bit
        if index < j:
            let temp = fft_work_buffer[index]
            fft_work_buffer[index] = fft_work_buffer[j]
            fft_work_buffer[j] = temp
        index += 1

    var len = 2
    while len <= n:
        let angle: float = -2.0 * rl.PI / float<-len
        let twiddle_unit = FFTComplex(
            real = float<-math.cos(double<-angle),
            imaginary = float<-math.sin(double<-angle)
        )

        index = 0
        while index < n:
            var twiddle_current = FFTComplex(real = 1.0, imaginary = 0.0)
            j = 0
            while j < len / 2:
                let even = fft_work_buffer[index + j]
                let odd = fft_work_buffer[index + j + len / 2]
                let twiddled_odd = FFTComplex(
                    real = odd.real * twiddle_current.real - odd.imaginary * twiddle_current.imaginary,
                    imaginary = odd.real * twiddle_current.imaginary + odd.imaginary * twiddle_current.real
                )

                fft_work_buffer[index + j].real = even.real + twiddled_odd.real
                fft_work_buffer[index + j].imaginary = even.imaginary + twiddled_odd.imaginary
                fft_work_buffer[index + j + len / 2].real = even.real - twiddled_odd.real
                fft_work_buffer[index + j + len / 2].imaginary = even.imaginary - twiddled_odd.imaginary

                let twiddle_real_next = twiddle_current.real * twiddle_unit.real - twiddle_current.imaginary * twiddle_unit.imaginary
                twiddle_current.imaginary = twiddle_current.real * twiddle_unit.imaginary + twiddle_current.imaginary * twiddle_unit.real
                twiddle_current.real = twiddle_real_next
                j += 1
            index += len
        len <<= 1


function capture_frame(audio_samples: ptr[float]) -> void:
    var index = 0
    while index < FFT_WINDOW_SIZE:
        let x: float = (2.0 * rl.PI * float<-index) / float<-(FFT_WINDOW_SIZE - 1)
        let blackman_weight: float = 0.42 - 0.5 * float<-math.cos(double<-x) + 0.08 * float<-math.cos(double<-(2.0 * x))
        unsafe:
            fft_work_buffer[index].real = read(audio_samples + ptr_uint<-index) * blackman_weight
        fft_work_buffer[index].imaginary = 0.0
        index += 1

    cooley_tukey_fft_slow(FFT_WINDOW_SIZE)

    index = 0
    while index < FFT_WINDOW_SIZE:
        fft_spectrum[index] = fft_work_buffer[index]
        index += 1

    var smoothed_spectrum: array[float, BUFFER_SIZE] = zero[array[float, BUFFER_SIZE]]
    var bin = 0
    while bin < BUFFER_SIZE:
        let re = fft_work_buffer[bin].real
        let im = fft_work_buffer[bin].imaginary
        let linear_magnitude = float<-math.sqrt(double<-((re * re) + (im * im))) / float<-FFT_WINDOW_SIZE
        let smoothed_magnitude = SMOOTHING_TIME_CONSTANT * fft_prev_magnitudes[bin] + (1.0 - SMOOTHING_TIME_CONSTANT) * linear_magnitude
        fft_prev_magnitudes[bin] = smoothed_magnitude

        var safe_magnitude = smoothed_magnitude
        if safe_magnitude <= 1e-40:
            safe_magnitude = 1e-40

        let db = float<-(math.log(double<-safe_magnitude) * double<-DB_TO_LINEAR_SCALE)
        let normalized = (db - MIN_DECIBELS) * INVERSE_DECIBEL_RANGE
        if normalized < 0.0:
            smoothed_spectrum[bin] = 0.0
        else if normalized > 1.0:
            smoothed_spectrum[bin] = 1.0
        else:
            smoothed_spectrum[bin] = normalized
        bin += 1

    fft_last_fft_time = rl.get_time()

    bin = 0
    while bin < BUFFER_SIZE:
        fft_history[fft_history_pos][bin] = smoothed_spectrum[bin]
        bin += 1
    fft_history_pos = (fft_history_pos + 1) % FFT_HISTORY_LEN


function render_frame(fft_image: ref[rl.Image]) -> void:
    var frames_since_tapback = float<-math.floor(double<-(fft_tapback_pos / float<-WINDOW_TIME))
    if frames_since_tapback < 0.0:
        frames_since_tapback = 0.0
    if frames_since_tapback > float<-(FFT_HISTORY_LEN - 1):
        frames_since_tapback = float<-(FFT_HISTORY_LEN - 1)

    var history_position = (fft_history_pos - 1 - int<-frames_since_tapback) % FFT_HISTORY_LEN
    if history_position < 0:
        history_position += FFT_HISTORY_LEN

    var bin = 0
    while bin < BUFFER_SIZE:
        fft_image.draw_pixel(
            bin,
            FFT_ROW,
            rl.color_from_normalized(rl.Vector4(
                x = fft_history[history_position][bin],
                y = UNUSED_CHANNEL,
                z = UNUSED_CHANNEL,
                w = UNUSED_CHANNEL
            ))
        )
        bin += 1


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [audio] example - spectrum visualizer")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var fft_image = rl.gen_image_color(BUFFER_SIZE, TEXTURE_HEIGHT, rl.WHITE)
    defer rl.unload_image(fft_image)
    let fft_texture = rl.load_texture_from_image(fft_image)
    defer rl.unload_texture(fft_texture)
    let buffer_a = rl.load_render_texture(SCREEN_WIDTH, SCREEN_HEIGHT)
    defer rl.unload_render_texture(buffer_a)
    let i_resolution = rl.Vector2(x = float<-SCREEN_WIDTH, y = float<-SCREEN_HEIGHT)

    let shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/fft.fs", GLSL_VERSION))
    defer rl.unload_shader(shader)

    let i_resolution_location = rl.get_shader_location(shader, "iResolution")
    let i_channel0_location = rl.get_shader_location(shader, "iChannel0")
    rl.set_shader_value(shader, i_resolution_location, i_resolution, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
    rl.set_shader_value_texture(shader, i_channel0_location, fft_texture)

    rl.init_audio_device()
    defer rl.close_audio_device()
    rl.set_audio_stream_buffer_size_default(AUDIO_STREAM_RING_BUFFER_SIZE)

    var wav = rl.load_wave("country.mp3")
    defer rl.unload_wave(wav)
    rl.wave_format(ptr_of(wav), SAMPLE_RATE, PER_SAMPLE_BIT_DEPTH, MONO)

    let audio_stream = rl.load_audio_stream(uint<-SAMPLE_RATE, uint<-PER_SAMPLE_BIT_DEPTH, uint<-MONO)
    defer rl.unload_audio_stream(audio_stream)
    rl.play_audio_stream(audio_stream)

    var wav_cursor: uint = 0
    let wav_pcm16 = unsafe: ptr[short]<-wav.data
    var chunk_samples: array[short, AUDIO_STREAM_RING_BUFFER_SIZE] = zero[array[short, AUDIO_STREAM_RING_BUFFER_SIZE]]
    var audio_samples: array[float, FFT_WINDOW_SIZE] = zero[array[float, FFT_WINDOW_SIZE]]

    rl.set_target_fps(60)

    while not rl.window_should_close():
        while rl.is_audio_stream_processed(audio_stream):
            var index = 0
            while index < AUDIO_STREAM_RING_BUFFER_SIZE:
                var left: int = 0
                var right: int = 0
                unsafe:
                    if wav.channels == uint<-2:
                        left = int<-read(wav_pcm16 + ptr_uint<-(wav_cursor * uint<-2))
                        right = int<-read(wav_pcm16 + ptr_uint<-(wav_cursor * uint<-2 + uint<-1))
                    else:
                        left = int<-read(wav_pcm16 + ptr_uint<-wav_cursor)
                        right = left

                chunk_samples[index] = short<-((left + right) / 2)
                wav_cursor += uint<-1
                if wav_cursor >= wav.frameCount:
                    wav_cursor = 0
                index += 1

            rl.update_audio_stream(audio_stream, ptr_of(chunk_samples[0]), AUDIO_STREAM_RING_BUFFER_SIZE)

            index = 0
            while index < FFT_WINDOW_SIZE:
                audio_samples[index] = ((float<-chunk_samples[index * 2] + float<-chunk_samples[index * 2 + 1]) * 0.5) / 32767.0
                index += 1

        capture_frame(ptr_of(audio_samples[0]))
        render_frame(ref_of(fft_image))
        unsafe:
            rl.update_texture(fft_texture, ptr[ubyte]<-fft_image.data)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.begin_shader_mode(shader)
        rl.set_shader_value_texture(shader, i_channel0_location, fft_texture)
        rl.draw_texture_rec(
            buffer_a.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = float<-SCREEN_WIDTH, height = -float<-SCREEN_HEIGHT),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE
        )
        rl.end_shader_mode()
        rl.end_drawing()

    return 0
