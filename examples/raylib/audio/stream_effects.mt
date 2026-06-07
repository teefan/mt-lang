import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450

var delay_buffer: array[float, 96000] = zero[array[float, 96000]]
var delay_buffer_size: uint = uint<-96000
var delay_read_index: uint = uint<-2
var delay_write_index: uint = 0
var low_pass_state: array[float, 2] = zero[array[float, 2]]


function audio_process_effect_lpf(buffer: ptr[void], frames: uint) -> void:
    unsafe:
        let buffer_data = ptr[float]<-buffer
        let cutoff: float = 70.0 / 44100.0
        let k: float = cutoff / (cutoff + 0.1591549431)

        var index: uint = 0
        while index < frames * uint<-2:
            let left = read(buffer_data + ptr_uint<-index)
            let right = read(buffer_data + ptr_uint<-(index + uint<-1))

            low_pass_state[0] += k * (left - low_pass_state[0])
            low_pass_state[1] += k * (right - low_pass_state[1])
            read(buffer_data + ptr_uint<-index) = low_pass_state[0]
            read(buffer_data + ptr_uint<-(index + uint<-1)) = low_pass_state[1]
            index += uint<-2


function audio_process_effect_delay(buffer: ptr[void], frames: uint) -> void:
    unsafe:
        let buffer_data = ptr[float]<-buffer

        var index: uint = 0
        while index < frames * uint<-2:
            let left_delay = delay_buffer[int<-delay_read_index]
            delay_read_index += uint<-1
            let right_delay = delay_buffer[int<-delay_read_index]
            delay_read_index += uint<-1
            if delay_read_index == delay_buffer_size:
                delay_read_index = 0

            read(buffer_data + ptr_uint<-index) = 0.5 * read(buffer_data + ptr_uint<-index) + 0.5 * left_delay
            read(buffer_data + ptr_uint<-(index + uint<-1)) = 0.5 * read(buffer_data + ptr_uint<-(index + uint<-1)) + 0.5 * right_delay

            delay_buffer[int<-delay_write_index] = read(buffer_data + ptr_uint<-index)
            delay_write_index += uint<-1
            delay_buffer[int<-delay_write_index] = read(buffer_data + ptr_uint<-(index + uint<-1))
            delay_write_index += uint<-1
            if delay_write_index == delay_buffer_size:
                delay_write_index = 0

            index += uint<-2


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [audio] example - stream effects")
    defer rl.close_window()

    rl.init_audio_device()
    defer rl.close_audio_device()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let music = rl.load_music_stream("country.mp3")
    defer rl.unload_music_stream(music)
    rl.play_music_stream(music)

    var time_played: float = 0.0
    var pause = false
    var enable_effect_lpf = false
    var enable_effect_delay = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_music_stream(music)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            rl.stop_music_stream(music)
            rl.play_music_stream(music)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_P):
            pause = not pause
            if pause:
                rl.pause_music_stream(music)
            else:
                rl.resume_music_stream(music)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_F):
            enable_effect_lpf = not enable_effect_lpf
            if enable_effect_lpf:
                rl.attach_audio_stream_processor(music.stream, audio_process_effect_lpf)
            else:
                rl.detach_audio_stream_processor(music.stream, audio_process_effect_lpf)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_D):
            enable_effect_delay = not enable_effect_delay
            if enable_effect_delay:
                rl.attach_audio_stream_processor(music.stream, audio_process_effect_delay)
            else:
                rl.detach_audio_stream_processor(music.stream, audio_process_effect_delay)

        time_played = rl.get_music_time_played(music) / rl.get_music_time_length(music)
        if time_played > 1.0:
            time_played = 1.0

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("MUSIC SHOULD BE PLAYING!", 245, 150, 20, rl.LIGHTGRAY)

        rl.draw_rectangle(200, 180, 400, 12, rl.LIGHTGRAY)
        rl.draw_rectangle(200, 180, int<-(time_played * 400.0), 12, rl.MAROON)
        rl.draw_rectangle_lines(200, 180, 400, 12, rl.GRAY)

        rl.draw_text("PRESS SPACE TO RESTART MUSIC", 215, 230, 20, rl.LIGHTGRAY)
        rl.draw_text("PRESS P TO PAUSE/RESUME MUSIC", 208, 260, 20, rl.LIGHTGRAY)

        var lpf_state = "OFF"
        if enable_effect_lpf:
            lpf_state = "ON"
        var delay_state = "OFF"
        if enable_effect_delay:
            delay_state = "ON"
        let lpf_text = text.cstr_as_str(rl.text_format("PRESS F TO TOGGLE LPF EFFECT: %s", lpf_state))
        let delay_text = text.cstr_as_str(rl.text_format("PRESS D TO TOGGLE DELAY EFFECT: %s", delay_state))
        rl.draw_text(lpf_text, 200, 320, 20, rl.GRAY)
        rl.draw_text(delay_text, 180, 350, 20, rl.GRAY)
        rl.end_drawing()

    return 0
