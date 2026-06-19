import std.math as math
import std.raylib as rl
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const BUFFER_SIZE: int = 4096
const SAMPLE_RATE: int = 44100
const TWO_PI: float = rl.PI * 2.0


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [audio] example - raw stream")
    defer rl.close_window()

    rl.init_audio_device()
    defer rl.close_audio_device()

    rl.set_audio_stream_buffer_size_default(BUFFER_SIZE)
    var buffer: array[float, BUFFER_SIZE] = zero[array[float, BUFFER_SIZE]]

    let stream = rl.load_audio_stream(uint<-SAMPLE_RATE, 32u, 1u)
    defer rl.unload_audio_stream(stream)

    var pan: float = 0.0
    rl.set_audio_stream_pan(stream, pan)
    rl.play_audio_stream(stream)

    var sine_frequency = 440
    var new_sine_frequency = 440
    var sine_index = 0
    var sine_start_time: double = 0.0

    rl.set_target_fps(30)

    while not rl.window_should_close():
        if rl.is_key_down(rl.KeyboardKey.KEY_UP):
            new_sine_frequency += 10
            if new_sine_frequency > 12500:
                new_sine_frequency = 12500
        if rl.is_key_down(rl.KeyboardKey.KEY_DOWN):
            new_sine_frequency -= 10
            if new_sine_frequency < 20:
                new_sine_frequency = 20

        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT):
            pan -= 0.01
            if pan < -1.0:
                pan = -1.0
            rl.set_audio_stream_pan(stream, pan)
        if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT):
            pan += 0.01
            if pan > 1.0:
                pan = 1.0
            rl.set_audio_stream_pan(stream, pan)

        if rl.is_audio_stream_processed(stream):
            var index = 0
            while index < BUFFER_SIZE:
                let wavelength = SAMPLE_RATE / sine_frequency
                buffer[index] = float<-math.sin(double<-(TWO_PI * float<-sine_index / float<-wavelength))
                sine_index += 1

                if sine_index >= wavelength:
                    sine_frequency = new_sine_frequency
                    sine_index = 0
                    sine_start_time = rl.get_time()
                index += 1

            rl.update_audio_stream(stream, ptr_of(buffer[0]), BUFFER_SIZE)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text(
            text.cstr_as_str(rl.text_format("sine frequency: %i", sine_frequency)),
            SCREEN_WIDTH - 220,
            10,
            20,
            rl.RED
        )
        rl.draw_text(text.cstr_as_str(rl.text_format("pan: %.2f", pan)), SCREEN_WIDTH - 220, 30, 20, rl.RED)
        rl.draw_text("Up/down to change frequency", 10, 10, 20, rl.DARKGRAY)
        rl.draw_text("Left/right to pan", 10, 30, 20, rl.DARKGRAY)

        let window_start = int<-((rl.get_time() - sine_start_time) * double<-SAMPLE_RATE)
        let window_size = int<-(0.1 * double<-SAMPLE_RATE)
        let wavelength = SAMPLE_RATE / sine_frequency

        var index = 0
        while index < SCREEN_WIDTH:
            let t0 = window_start + index * window_size / SCREEN_WIDTH
            let t1 = window_start + (index + 1) * window_size / SCREEN_WIDTH
            let start_pos = rl.Vector2(
                x = float<-index,
                y = float<-(250.0 + 50.0 * math.sin(double<-(TWO_PI * float<-t0 / float<-wavelength)))
            )
            let end_pos = rl.Vector2(
                x = float<-(index + 1),
                y = float<-(250.0 + 50.0 * math.sin(double<-(TWO_PI * float<-t1 / float<-wavelength)))
            )
            rl.draw_line_v(start_pos, end_pos, rl.RED)
            index += 1

        rl.end_drawing()

    return 0
