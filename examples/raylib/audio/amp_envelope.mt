import std.math as math
import std.raygui as gui
import std.raylib as rl
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const BUFFER_SIZE: int = 4096
const SAMPLE_RATE: int = 44100

enum ADSRState: int
    IDLE = 0
    ATTACK = 1
    DECAY = 2
    SUSTAIN = 3
    RELEASE = 4

struct Envelope:
    attack_time: float
    decay_time: float
    sustain_level: float
    release_time: float
    current_value: float
    state: ADSRState


function fill_audio_buffer(index: int, buffer: ptr[float], envelope_value: float, audio_time: ref[float]) -> void:
    let frequency: float = 440.0
    unsafe: read(buffer + ptr_uint<-index) = envelope_value * float<-math.sin(double<-(2.0 * rl.PI * frequency * read(audio_time)))
    read(audio_time) += 1.0 / float<-SAMPLE_RATE


function update_envelope(env: ref[Envelope]) -> void:
    let sample_time: float = 1.0 / float<-SAMPLE_RATE

    if read(env).state == ADSRState.ATTACK:
        read(env).current_value += (1.0 / read(env).attack_time) * sample_time
        if read(env).current_value >= 1.0:
            read(env).current_value = 1.0
            read(env).state = ADSRState.DECAY
    else if read(env).state == ADSRState.DECAY:
        read(env).current_value -= ((1.0 - read(env).sustain_level) / read(env).decay_time) * sample_time
        if read(env).current_value <= read(env).sustain_level:
            read(env).current_value = read(env).sustain_level
            read(env).state = ADSRState.SUSTAIN
    else if read(env).state == ADSRState.SUSTAIN:
        read(env).current_value = read(env).sustain_level
    else if read(env).state == ADSRState.RELEASE:
        read(env).current_value -= (read(env).sustain_level / read(env).release_time) * sample_time
        if read(env).current_value <= 0.001:
            read(env).current_value = 0.0
            read(env).state = ADSRState.IDLE


function draw_adsr_graph(env: ref[Envelope], bounds: rl.Rectangle) -> void:
    rl.draw_rectangle_rec(bounds, rl.fade(rl.LIGHTGRAY, 0.3))
    rl.draw_rectangle_lines_ex(bounds, 1.0, rl.GRAY)

    let sustain_width: float = 1.0
    let total_time = read(env).attack_time + read(env).decay_time + sustain_width + read(env).release_time
    let scale_x = bounds.width / total_time
    let scale_y = bounds.height

    let start = rl.Vector2(x = bounds.x, y = bounds.y + bounds.height)
    let peak = rl.Vector2(x = start.x + read(env).attack_time * scale_x, y = bounds.y)
    let sustain = rl.Vector2(
        x = peak.x + read(env).decay_time * scale_x,
        y = bounds.y + (1.0 - read(env).sustain_level) * scale_y
    )
    let release = rl.Vector2(x = sustain.x + sustain_width * scale_x, y = sustain.y)
    let end = rl.Vector2(x = release.x + read(env).release_time * scale_x, y = bounds.y + bounds.height)

    rl.draw_line_v(start, peak, rl.SKYBLUE)
    rl.draw_line_v(peak, sustain, rl.BLUE)
    rl.draw_line_v(sustain, release, rl.DARKBLUE)
    rl.draw_line_v(release, end, rl.ORANGE)
    rl.draw_text("ADSR Visualizer", int<-bounds.x, int<-bounds.y - 20, 10, rl.DARKGRAY)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [audio] example - amp envelope")
    defer rl.close_window()

    rl.init_audio_device()
    defer rl.close_audio_device()

    rl.set_audio_stream_buffer_size_default(BUFFER_SIZE)
    var buffer: array[float, BUFFER_SIZE] = zero[array[float, BUFFER_SIZE]]
    let stream = rl.load_audio_stream(uint<-SAMPLE_RATE, 32u, 1u)
    defer rl.unload_audio_stream(stream)

    var audio_time: float = 0.0
    var env = Envelope(
        attack_time = 1.0,
        decay_time = 1.0,
        sustain_level = 0.5,
        release_time = 1.0,
        current_value = 0.0,
        state = ADSRState.IDLE
    )

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            env.state = ADSRState.ATTACK
        if rl.is_key_released(rl.KeyboardKey.KEY_SPACE) and env.state != ADSRState.IDLE:
            env.state = ADSRState.RELEASE

        if rl.is_audio_stream_processed(stream):
            if env.state != ADSRState.IDLE or env.current_value > 0.0:
                var index = 0
                while index < BUFFER_SIZE:
                    update_envelope(ref_of(env))
                    fill_audio_buffer(index, ptr_of(buffer[0]), env.current_value, ref_of(audio_time))
                    index += 1
            else:
                var index = 0
                while index < BUFFER_SIZE:
                    buffer[index] = 0.0
                    index += 1
                audio_time = 0.0

            rl.update_audio_stream(stream, ptr_of(buffer[0]), BUFFER_SIZE)

        if not rl.is_audio_stream_playing(stream):
            rl.play_audio_stream(stream)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        let attack_text = text.cstr_as_str(rl.text_format("%2.2fs", env.attack_time))
        let decay_text = text.cstr_as_str(rl.text_format("%2.2fs", env.decay_time))
        let sustain_text = text.cstr_as_str(rl.text_format("%2.2f", env.sustain_level))
        let release_text = text.cstr_as_str(rl.text_format("%2.2fs", env.release_time))

        gui.slider_bar(
            rl.Rectangle(x = 100.0, y = 60.0, width = 400.0, height = 30.0),
            "Attack (s)",
            attack_text,
            env.attack_time,
            0.1,
            3.0
        )
        gui.slider_bar(
            rl.Rectangle(x = 100.0, y = 100.0, width = 400.0, height = 30.0),
            "Decay (s)",
            decay_text,
            env.decay_time,
            0.1,
            3.0
        )
        gui.slider_bar(
            rl.Rectangle(x = 100.0, y = 140.0, width = 400.0, height = 30.0),
            "Sustain",
            sustain_text,
            env.sustain_level,
            0.0,
            1.0
        )
        gui.slider_bar(
            rl.Rectangle(x = 100.0, y = 180.0, width = 400.0, height = 30.0),
            "Release (s)",
            release_text,
            env.release_time,
            0.1,
            3.0
        )

        draw_adsr_graph(ref_of(env), rl.Rectangle(x = 100.0, y = 250.0, width = 400.0, height = 100.0))
        rl.draw_circle_v(rl.Vector2(x = 520.0, y = 350.0 - env.current_value * 100.0), 5.0, rl.MAROON)
        let current_gain_text = text.cstr_as_str(rl.text_format("Current Gain: %2.2f", env.current_value))
        rl.draw_text(current_gain_text, 535, int<-(345.0 - env.current_value * 100.0), 10, rl.MAROON)
        rl.draw_text("Press SPACE to PLAY the sound!", 200, 400, 20, rl.LIGHTGRAY)
        rl.end_drawing()

    return 0
