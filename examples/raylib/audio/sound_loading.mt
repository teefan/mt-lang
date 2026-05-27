import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [audio] example - sound loading")
    defer rl.close_window()

    rl.init_audio_device()
    defer rl.close_audio_device()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let fx_wav = rl.load_sound("sound.wav")
    defer rl.unload_sound(fx_wav)
    let fx_ogg = rl.load_sound("target.ogg")
    defer rl.unload_sound(fx_ogg)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            rl.play_sound(fx_wav)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER):
            rl.play_sound(fx_ogg)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.draw_text("Press SPACE to PLAY the WAV sound!", 200, 180, 20, rl.LIGHTGRAY)
        rl.draw_text("Press ENTER to PLAY the OGG sound!", 200, 220, 20, rl.LIGHTGRAY)
        rl.end_drawing()

    return 0
