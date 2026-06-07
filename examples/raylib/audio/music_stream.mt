import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [audio] example - music stream")
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
    var pan: float = 0.0
    var volume: float = 0.8

    rl.set_music_pan(music, pan)
    rl.set_music_volume(music, volume)
    rl.set_target_fps(30)

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

        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT):
            pan -= 0.05
            if pan < -1.0:
                pan = -1.0
            rl.set_music_pan(music, pan)
        else if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT):
            pan += 0.05
            if pan > 1.0:
                pan = 1.0
            rl.set_music_pan(music, pan)

        if rl.is_key_down(rl.KeyboardKey.KEY_DOWN):
            volume -= 0.05
            if volume < 0.0:
                volume = 0.0
            rl.set_music_volume(music, volume)
        else if rl.is_key_down(rl.KeyboardKey.KEY_UP):
            volume += 0.05
            if volume > 1.0:
                volume = 1.0
            rl.set_music_volume(music, volume)

        time_played = rl.get_music_time_played(music) / rl.get_music_time_length(music)
        if time_played > 1.0:
            time_played = 1.0

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text("MUSIC SHOULD BE PLAYING!", 255, 150, 20, rl.LIGHTGRAY)
        rl.draw_text("LEFT-RIGHT for PAN CONTROL", 320, 74, 10, rl.DARKBLUE)
        rl.draw_rectangle(300, 100, 200, 12, rl.LIGHTGRAY)
        rl.draw_rectangle_lines(300, 100, 200, 12, rl.GRAY)
        rl.draw_rectangle(int<-(300.0 + ((pan + 1.0) / 2.0) * 200.0 - 5.0), 92, 10, 28, rl.DARKGRAY)

        rl.draw_rectangle(200, 200, 400, 12, rl.LIGHTGRAY)
        rl.draw_rectangle(200, 200, int<-(time_played * 400.0), 12, rl.MAROON)
        rl.draw_rectangle_lines(200, 200, 400, 12, rl.GRAY)

        rl.draw_text("PRESS SPACE TO RESTART MUSIC", 215, 250, 20, rl.LIGHTGRAY)
        rl.draw_text("PRESS P TO PAUSE/RESUME MUSIC", 208, 280, 20, rl.LIGHTGRAY)
        rl.draw_text("UP-DOWN for VOLUME CONTROL", 320, 334, 10, rl.DARKGREEN)
        rl.draw_rectangle(300, 360, 200, 12, rl.LIGHTGRAY)
        rl.draw_rectangle_lines(300, 360, 200, 12, rl.GRAY)
        rl.draw_rectangle(int<-(300.0 + volume * 200.0 - 5.0), 352, 10, 28, rl.DARKGRAY)
        rl.end_drawing()

    return 0
