module examples.raylib.audio.audio_sound_multi

import std.c.raylib as rl

const max_sounds: i32 = 10
const screen_width: i32 = 800
const screen_height: i32 = 450
const sound_path: cstr = c"resources/sound.wav"
const prompt_text: cstr = c"Press SPACE to PLAY a WAV sound!"
const window_title: cstr = c"raylib [audio] example - sound multi"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.InitAudioDevice()
    defer rl.CloseAudioDevice()

    var sound_array = zero[array[rl.Sound, 10]]()
    sound_array[0] = rl.LoadSound(sound_path)
    defer rl.UnloadSound(sound_array[0])

    for index in range(1, max_sounds):
        sound_array[index] = rl.LoadSoundAlias(sound_array[0])
    defer:
        for index in range(1, max_sounds):
            rl.UnloadSoundAlias(sound_array[index])

    var current_sound = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            rl.PlaySound(sound_array[current_sound])
            current_sound += 1
            if current_sound >= max_sounds:
                current_sound = 0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawText(prompt_text, 200, 180, 20, rl.LIGHTGRAY)

    return 0
