import std.math as math
import std.raylib as rl
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const BUFFER_SIZE: int = 4096
const SAMPLE_RATE: int = 44100
const SAMPLE_RATE_F: float = 44100.0
const LAST_WINDOW_SIZE: int = SAMPLE_RATE / 100
const LAST_WINDOW_START: int = SAMPLE_RATE - LAST_WINDOW_SIZE
const TWO_PI: float = rl.PI * 2.0

enum WaveType: int
    SINE = 0
    SQUARE = 1
    TRIANGLE = 2
    SAWTOOTH = 3

var wave_frequency: int = 440
var new_wave_frequency: int = 440
var wave_index: int = 0
var waveform_buffer: array[float, SAMPLE_RATE] = zero[array[float, SAMPLE_RATE]]


function save_synthesized_samples(frames_out: ptr[void], frame_count: uint) -> void:
    unsafe:
        let samples = ptr[float]<-frames_out
        var index = 0
        while index < SAMPLE_RATE - int<-frame_count:
            waveform_buffer[index] = waveform_buffer[index + int<-frame_count]
            index += 1

        index = 0
        while index < int<-frame_count:
            waveform_buffer[SAMPLE_RATE - int<-frame_count + index] = read(samples + ptr_uint<-index)
            index += 1


function sine_callback(frames_out: ptr[void], frame_count: uint) -> void:
    unsafe:
        let samples = ptr[float]<-frames_out
        let wavelength = SAMPLE_RATE / wave_frequency

        var index: uint = 0
        while index < frame_count:
            read(samples + ptr_uint<-index) = float<-math.sin(double<-(TWO_PI * float<-wave_index / float<-wavelength))
            wave_index += 1
            if wave_index >= wavelength:
                wave_frequency = new_wave_frequency
                wave_index = 0
            index += uint<-1

    save_synthesized_samples(frames_out, frame_count)


function square_callback(frames_out: ptr[void], frame_count: uint) -> void:
    unsafe:
        let samples = ptr[float]<-frames_out
        let wavelength = SAMPLE_RATE / wave_frequency

        var index: uint = 0
        while index < frame_count:
            if wave_index < wavelength / 2:
                read(samples + ptr_uint<-index) = 1.0
            else:
                read(samples + ptr_uint<-index) = -1.0
            wave_index += 1
            if wave_index >= wavelength:
                wave_frequency = new_wave_frequency
                wave_index = 0
            index += uint<-1

    save_synthesized_samples(frames_out, frame_count)


function triangle_callback(frames_out: ptr[void], frame_count: uint) -> void:
    unsafe:
        let samples = ptr[float]<-frames_out
        let wavelength = SAMPLE_RATE / wave_frequency

        var index: uint = 0
        while index < frame_count:
            if wave_index < wavelength / 2:
                read(samples + ptr_uint<-index) = float<-(-1.0 + (2.0 * float<-wave_index / float<-(wavelength / 2)))
            else:
                read(samples + ptr_uint<-index) = float<-(1.0 - (2.0 * float<-(wave_index - wavelength / 2) / float<-(wavelength / 2)))
            wave_index += 1
            if wave_index >= wavelength:
                wave_frequency = new_wave_frequency
                wave_index = 0
            index += uint<-1

    save_synthesized_samples(frames_out, frame_count)


function sawtooth_callback(frames_out: ptr[void], frame_count: uint) -> void:
    unsafe:
        let samples = ptr[float]<-frames_out
        let wavelength = SAMPLE_RATE / wave_frequency

        var index: uint = 0
        while index < frame_count:
            read(samples + ptr_uint<-index) = float<-(-1.0 + (2.0 * float<-wave_index / float<-wavelength))
            wave_index += 1
            if wave_index >= wavelength:
                wave_frequency = new_wave_frequency
                wave_index = 0
            index += uint<-1

    save_synthesized_samples(frames_out, frame_count)


function apply_wave_callback(stream: rl.AudioStream, wave_type: WaveType) -> void:
    if wave_type == WaveType.SINE:
        rl.set_audio_stream_callback(stream, sine_callback)
    else if wave_type == WaveType.SQUARE:
        rl.set_audio_stream_callback(stream, square_callback)
    else if wave_type == WaveType.TRIANGLE:
        rl.set_audio_stream_callback(stream, triangle_callback)
    else:
        rl.set_audio_stream_callback(stream, sawtooth_callback)


function wave_type_name(wave_type: WaveType) -> str:
    if wave_type == WaveType.SINE:
        return "sine"
    else if wave_type == WaveType.SQUARE:
        return "square"
    else if wave_type == WaveType.TRIANGLE:
        return "triangle"

    return "sawtooth"


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [audio] example - stream callback")
    defer rl.close_window()

    rl.init_audio_device()
    defer rl.close_audio_device()

    rl.set_audio_stream_buffer_size_default(BUFFER_SIZE)
    let stream = rl.load_audio_stream(uint<-SAMPLE_RATE, uint<-32, uint<-1)
    defer rl.unload_audio_stream(stream)
    rl.play_audio_stream(stream)

    var wave_type = WaveType.SINE
    apply_wave_callback(stream, wave_type)

    rl.set_target_fps(30)

    while not rl.window_should_close():
        if rl.is_key_down(rl.KeyboardKey.KEY_UP):
            new_wave_frequency += 10
            if new_wave_frequency > 12500:
                new_wave_frequency = 12500

        if rl.is_key_down(rl.KeyboardKey.KEY_DOWN):
            new_wave_frequency -= 10
            if new_wave_frequency < 20:
                new_wave_frequency = 20

        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            if wave_type == WaveType.SINE:
                wave_type = WaveType.SAWTOOTH
            else if wave_type == WaveType.SQUARE:
                wave_type = WaveType.SINE
            else if wave_type == WaveType.TRIANGLE:
                wave_type = WaveType.SQUARE
            else:
                wave_type = WaveType.TRIANGLE
            apply_wave_callback(stream, wave_type)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            if wave_type == WaveType.SINE:
                wave_type = WaveType.SQUARE
            else if wave_type == WaveType.SQUARE:
                wave_type = WaveType.TRIANGLE
            else if wave_type == WaveType.TRIANGLE:
                wave_type = WaveType.SAWTOOTH
            else:
                wave_type = WaveType.SINE
            apply_wave_callback(stream, wave_type)

        let frequency_text = text.cstr_as_str(rl.text_format("frequency: %i", new_wave_frequency))
        let wave_type_text = text.cstr_as_str(rl.text_format("wave type: %s", wave_type_name(wave_type)))

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.draw_text(frequency_text, SCREEN_WIDTH - 220, 10, 20, rl.RED)
        rl.draw_text(wave_type_text, SCREEN_WIDTH - 220, 30, 20, rl.RED)
        rl.draw_text("Up/down to change frequency", 10, 10, 20, rl.DARKGRAY)
        rl.draw_text("Left/right to change wave type", 10, 30, 20, rl.DARKGRAY)

        var index = 0
        while index < SCREEN_WIDTH:
            let start_index = LAST_WINDOW_START + index * LAST_WINDOW_SIZE / SCREEN_WIDTH
            let end_index = LAST_WINDOW_START + (index + 1) * LAST_WINDOW_SIZE / SCREEN_WIDTH
            let start_pos = rl.Vector2(x = float<-index, y = 250.0 - 50.0 * waveform_buffer[start_index])
            let end_pos = rl.Vector2(x = float<-(index + 1), y = 250.0 - 50.0 * waveform_buffer[end_index])
            rl.draw_line_v(start_pos, end_pos, rl.RED)
            index += 1

        rl.end_drawing()

    return 0
