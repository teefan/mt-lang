module examples.raylib.audio.audio_music_stream

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const music_path: cstr = c"../resources/country.mp3"
const playing_text: cstr = c"MUSIC SHOULD BE PLAYING!"
const pan_text: cstr = c"LEFT-RIGHT for PAN CONTROL"
const restart_text: cstr = c"PRESS SPACE TO RESTART MUSIC"
const pause_text: cstr = c"PRESS P TO PAUSE/RESUME MUSIC"
const volume_text: cstr = c"UP-DOWN for VOLUME CONTROL"
const window_title: cstr = c"raylib [audio] example - music stream"

def clamp(value: f32, min_value: f32, max_value: f32) -> f32:
    if value < min_value:
        return min_value
    if value > max_value:
        return max_value
    return value

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.InitAudioDevice()
    defer rl.CloseAudioDevice()

    let music = rl.LoadMusicStream(music_path)
    defer rl.UnloadMusicStream(music)

    rl.PlayMusicStream(music)

    var time_played: f32 = 0.0
    var pause = false

    var pan: f32 = 0.0
    rl.SetMusicPan(music, pan)

    var volume: f32 = 0.8
    rl.SetMusicVolume(music, volume)

    rl.SetTargetFPS(30)

    while not rl.WindowShouldClose():
        rl.UpdateMusicStream(music)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            rl.StopMusicStream(music)
            rl.PlayMusicStream(music)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_P):
            pause = not pause
            if pause:
                rl.PauseMusicStream(music)
            else:
                rl.ResumeMusicStream(music)

        if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT):
            pan = clamp(pan - 0.05, -1.0, 1.0)
            rl.SetMusicPan(music, pan)
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT):
            pan = clamp(pan + 0.05, -1.0, 1.0)
            rl.SetMusicPan(music, pan)

        if rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN):
            volume = clamp(volume - 0.05, 0.0, 1.0)
            rl.SetMusicVolume(music, volume)
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_UP):
            volume = clamp(volume + 0.05, 0.0, 1.0)
            rl.SetMusicVolume(music, volume)

        time_played = rl.GetMusicTimePlayed(music) / rl.GetMusicTimeLength(music)
        if time_played > 1.0:
            time_played = 1.0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawText(playing_text, 255, 150, 20, rl.LIGHTGRAY)

        rl.DrawText(pan_text, 320, 74, 10, rl.DARKBLUE)
        rl.DrawRectangle(300, 100, 200, 12, rl.LIGHTGRAY)
        rl.DrawRectangleLines(300, 100, 200, 12, rl.GRAY)
        rl.DrawRectangle(cast[i32](300.0 + ((pan + 1.0) / 2.0) * 200.0 - 5.0), 92, 10, 28, rl.DARKGRAY)

        rl.DrawRectangle(200, 200, 400, 12, rl.LIGHTGRAY)
        rl.DrawRectangle(200, 200, cast[i32](time_played * 400.0), 12, rl.MAROON)
        rl.DrawRectangleLines(200, 200, 400, 12, rl.GRAY)

        rl.DrawText(restart_text, 215, 250, 20, rl.LIGHTGRAY)
        rl.DrawText(pause_text, 208, 280, 20, rl.LIGHTGRAY)

        rl.DrawText(volume_text, 320, 334, 10, rl.DARKGREEN)
        rl.DrawRectangle(300, 360, 200, 12, rl.LIGHTGRAY)
        rl.DrawRectangleLines(300, 360, 200, 12, rl.GRAY)
        rl.DrawRectangle(cast[i32](300.0 + volume * 200.0 - 5.0), 352, 10, 28, rl.DARKGRAY)

    return 0
