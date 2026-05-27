import std.math as math
import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const VOLUME_HISTORY_SIZE: int = 400


var exponent: float = 1.0
var average_volume: array[float, VOLUME_HISTORY_SIZE] = zero[array[float, VOLUME_HISTORY_SIZE]]


function process_audio(buffer: ptr[void], frames: uint) -> void:
    unsafe:
        let samples = ptr[float]<-buffer
        var average: float = 0.0

        var frame: uint = 0
        while frame < frames:
            let left_index = ptr_uint<-frame * ptr_uint<-2
            let right_index = left_index + ptr_uint<-1

            let left_value = read(samples + left_index)
            let right_value = read(samples + right_index)

            var left_sign: float = 1.0
            if left_value < 0.0:
                left_sign = -1.0
            var right_sign: float = 1.0
            if right_value < 0.0:
                right_sign = -1.0

            let new_left = float<-(math.pow(math.abs(double<-left_value), double<-exponent) * double<-left_sign)
            let new_right = float<-(math.pow(math.abs(double<-right_value), double<-exponent) * double<-right_sign)

            read(samples + left_index) = new_left
            read(samples + right_index) = new_right

            average += float<-(math.abs(double<-new_left) / double<-frames)
            average += float<-(math.abs(double<-new_right) / double<-frames)
            frame += uint<-1

        var index = 0
        while index < VOLUME_HISTORY_SIZE - 1:
            average_volume[index] = average_volume[index + 1]
            index += 1

        average_volume[VOLUME_HISTORY_SIZE - 1] = average


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [audio] example - mixed processor")
    defer rl.close_window()

    rl.init_audio_device()
    defer rl.close_audio_device()

    rl.attach_audio_mixed_processor(process_audio)
    defer rl.detach_audio_mixed_processor(process_audio)

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let music = rl.load_music_stream("country.mp3")
    defer rl.unload_music_stream(music)
    let sound = rl.load_sound("coin.wav")
    defer rl.unload_sound(sound)

    rl.play_music_stream(music)
    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_music_stream(music)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            exponent -= 0.05
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            exponent += 0.05
        if exponent <= 0.5:
            exponent = 0.5
        if exponent >= 3.0:
            exponent = 3.0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            rl.play_sound(sound)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text("MUSIC SHOULD BE PLAYING!", 255, 150, 20, rl.LIGHTGRAY)
        rl.draw_text(text.cstr_as_str(rl.text_format("EXPONENT = %.2f", exponent)), 215, 180, 20, rl.LIGHTGRAY)

        rl.draw_rectangle(199, 199, 402, 34, rl.LIGHTGRAY)
        var index = 0
        while index < VOLUME_HISTORY_SIZE:
            rl.draw_line(201 + index, 232 - int<-(average_volume[index] * 32.0), 201 + index, 232, rl.MAROON)
            index += 1
        rl.draw_rectangle_lines(199, 199, 402, 34, rl.GRAY)

        rl.draw_text("PRESS SPACE TO PLAY OTHER SOUND", 200, 250, 20, rl.LIGHTGRAY)
        rl.draw_text("USE LEFT AND RIGHT ARROWS TO ALTER DISTORTION", 140, 280, 20, rl.LIGHTGRAY)
        rl.end_drawing()

    return 0
