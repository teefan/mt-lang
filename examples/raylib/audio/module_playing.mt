import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_CIRCLES: int = 64


struct CircleWave:
    position: rl.Vector2
    radius: float
    alpha: float
    speed: float
    color: rl.Color


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [audio] example - module playing")
    defer rl.close_window()

    rl.init_audio_device()
    defer rl.close_audio_device()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let colors = array[rl.Color, 14](rl.ORANGE, rl.RED, rl.GOLD, rl.LIME, rl.BLUE, rl.VIOLET, rl.BROWN, rl.LIGHTGRAY, rl.PINK, rl.YELLOW, rl.GREEN, rl.SKYBLUE, rl.PURPLE, rl.BEIGE)
    var circles: array[CircleWave, MAX_CIRCLES] = zero[array[CircleWave, MAX_CIRCLES]]

    var index = MAX_CIRCLES - 1
    while index >= 0:
        circles[index].alpha = 0.0
        circles[index].radius = float<-rl.get_random_value(10, 40)
        circles[index].position.x = float<-rl.get_random_value(int<-circles[index].radius, int<-(float<-SCREEN_WIDTH - circles[index].radius))
        circles[index].position.y = float<-rl.get_random_value(int<-circles[index].radius, int<-(float<-SCREEN_HEIGHT - circles[index].radius))
        circles[index].speed = float<-rl.get_random_value(1, 100) / 2000.0
        circles[index].color = colors[rl.get_random_value(0, 13)]
        index -= 1

    var music = rl.load_music_stream("mini1111.xm")
    defer rl.unload_music_stream(music)
    music.looping = false
    var pitch: float = 1.0
    rl.play_music_stream(music)

    var time_played: float = 0.0
    var pause = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_music_stream(music)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            rl.stop_music_stream(music)
            rl.play_music_stream(music)
            pause = false

        if rl.is_key_pressed(rl.KeyboardKey.KEY_P):
            pause = not pause
            if pause:
                rl.pause_music_stream(music)
            else:
                rl.resume_music_stream(music)

        if rl.is_key_down(rl.KeyboardKey.KEY_DOWN):
            pitch -= 0.01
        else if rl.is_key_down(rl.KeyboardKey.KEY_UP):
            pitch += 0.01

        rl.set_music_pitch(music, pitch)
        time_played = (rl.get_music_time_played(music) / rl.get_music_time_length(music)) * float<-(SCREEN_WIDTH - 40)

        index = MAX_CIRCLES - 1
        while index >= 0 and not pause:
            circles[index].alpha += circles[index].speed
            circles[index].radius += circles[index].speed * 10.0

            if circles[index].alpha > 1.0:
                circles[index].speed *= -1.0

            if circles[index].alpha <= 0.0:
                circles[index].alpha = 0.0
                circles[index].radius = float<-rl.get_random_value(10, 40)
                circles[index].position.x = float<-rl.get_random_value(int<-circles[index].radius, int<-(float<-SCREEN_WIDTH - circles[index].radius))
                circles[index].position.y = float<-rl.get_random_value(int<-circles[index].radius, int<-(float<-SCREEN_HEIGHT - circles[index].radius))
                circles[index].color = colors[rl.get_random_value(0, 13)]
                circles[index].speed = float<-rl.get_random_value(1, 100) / 2000.0
            index -= 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        index = MAX_CIRCLES - 1
        while index >= 0:
            rl.draw_circle_v(circles[index].position, circles[index].radius, rl.fade(circles[index].color, circles[index].alpha))
            index -= 1

        rl.draw_rectangle(20, SCREEN_HEIGHT - 32, SCREEN_WIDTH - 40, 12, rl.LIGHTGRAY)
        rl.draw_rectangle(20, SCREEN_HEIGHT - 32, int<-time_played, 12, rl.MAROON)
        rl.draw_rectangle_lines(20, SCREEN_HEIGHT - 32, SCREEN_WIDTH - 40, 12, rl.GRAY)

        rl.draw_rectangle(20, 20, 425, 145, rl.WHITE)
        rl.draw_rectangle_lines(20, 20, 425, 145, rl.GRAY)
        rl.draw_text("PRESS SPACE TO RESTART MUSIC", 40, 40, 20, rl.BLACK)
        rl.draw_text("PRESS P TO PAUSE/RESUME", 40, 70, 20, rl.BLACK)
        rl.draw_text("PRESS UP/DOWN TO CHANGE SPEED", 40, 100, 20, rl.BLACK)
        rl.draw_text(text.cstr_as_str(rl.text_format("SPEED: %f", pitch)), 40, 130, 20, rl.MAROON)
        rl.end_drawing()

    return 0
