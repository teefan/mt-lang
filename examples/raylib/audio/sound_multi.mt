import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_SOUNDS: int = 10


var sound_array: array[rl.Sound, MAX_SOUNDS] = zero[array[rl.Sound, MAX_SOUNDS]]


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [audio] example - sound multi")
    defer rl.close_window()

    rl.init_audio_device()
    defer rl.close_audio_device()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    sound_array[0] = rl.load_sound("sound.wav")
    defer rl.unload_sound(sound_array[0])

    var index = 1
    while index < MAX_SOUNDS:
        sound_array[index] = rl.load_sound_alias(sound_array[0])
        index += 1

    var current_sound = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            rl.play_sound(sound_array[current_sound])
            current_sound += 1
            if current_sound >= MAX_SOUNDS:
                current_sound = 0

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("Press SPACE to PLAY a WAV sound!", 200, 180, 20, rl.LIGHTGRAY)
        rl.end_drawing()

    index = 1
    while index < MAX_SOUNDS:
        rl.unload_sound_alias(sound_array[index])
        index += 1

    return 0
