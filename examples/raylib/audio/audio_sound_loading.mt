module examples.raylib.audio.audio_sound_loading

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const wav_path: cstr = c"../resources/sound.wav"
const ogg_path: cstr = c"../resources/target.ogg"
const wav_text: cstr = c"Press SPACE to PLAY the WAV sound!"
const ogg_text: cstr = c"Press ENTER to PLAY the OGG sound!"
const window_title: cstr = c"raylib [audio] example - sound loading"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.InitAudioDevice()
    defer rl.CloseAudioDevice()

    let fx_wav = rl.LoadSound(wav_path)
    defer rl.UnloadSound(fx_wav)

    let fx_ogg = rl.LoadSound(ogg_path)
    defer rl.UnloadSound(fx_ogg)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            rl.PlaySound(fx_wav)
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_ENTER):
            rl.PlaySound(fx_ogg)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawText(wav_text, 200, 180, 20, rl.LIGHTGRAY)
        rl.DrawText(ogg_text, 200, 220, 20, rl.LIGHTGRAY)

    return 0
