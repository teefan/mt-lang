module examples.raylib.audio.audio_module_playing

import std.c.raylib as rl

struct CircleWave:
    position: rl.Vector2
    radius: f32
    alpha: f32
    speed: f32
    color: rl.Color

const max_circles: i32 = 64
const screen_width: i32 = 800
const screen_height: i32 = 450
const music_path: cstr = c"../resources/mini1111.xm"
const restart_text: cstr = c"PRESS SPACE TO RESTART MUSIC"
const pause_text: cstr = c"PRESS P TO PAUSE/RESUME"
const speed_text: cstr = c"PRESS UP/DOWN TO CHANGE SPEED"
const speed_format: cstr = c"SPEED: %f"
const window_title: cstr = c"raylib [audio] example - module playing"

def random_circle(circles: ref[array[CircleWave, 64]], index: i32, colors: ref[array[rl.Color, 14]]) -> void:
    var items = value(circles)
    var palette = value(colors)
    var circle = items[index]
    circle.alpha = 0.0
    circle.radius = f32<-rl.GetRandomValue(10, 40)
    circle.position.x = f32<-rl.GetRandomValue(i32<-circle.radius, i32<-(screen_width - i32<-circle.radius))
    circle.position.y = f32<-rl.GetRandomValue(i32<-circle.radius, i32<-(screen_height - i32<-circle.radius))
    circle.speed = f32<-rl.GetRandomValue(1, 100) / 2000.0
    circle.color = palette[rl.GetRandomValue(0, 13)]
    items[index] = circle
    value(circles) = items

def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.InitAudioDevice()
    defer rl.CloseAudioDevice()

    var colors = zero[array[rl.Color, 14]]()
    colors[0] = rl.ORANGE
    colors[1] = rl.RED
    colors[2] = rl.GOLD
    colors[3] = rl.LIME
    colors[4] = rl.BLUE
    colors[5] = rl.VIOLET
    colors[6] = rl.BROWN
    colors[7] = rl.LIGHTGRAY
    colors[8] = rl.PINK
    colors[9] = rl.YELLOW
    colors[10] = rl.GREEN
    colors[11] = rl.SKYBLUE
    colors[12] = rl.PURPLE
    colors[13] = rl.BEIGE

    var circles = zero[array[CircleWave, 64]]()
    for index in range(0, max_circles):
        random_circle(addr(circles), max_circles - 1 - index, addr(colors))

    var music = rl.LoadMusicStream(music_path)
    defer rl.UnloadMusicStream(music)
    music.looping = false

    var pitch: f32 = 1.0
    var time_played: f32 = 0.0
    var pause = false

    rl.PlayMusicStream(music)
    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateMusicStream(music)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            rl.StopMusicStream(music)
            rl.PlayMusicStream(music)
            pause = false

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_P):
            pause = not pause
            if pause:
                rl.PauseMusicStream(music)
            else:
                rl.ResumeMusicStream(music)

        if rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN):
            pitch -= 0.01
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_UP):
            pitch += 0.01

        rl.SetMusicPitch(music, pitch)
        time_played = rl.GetMusicTimePlayed(music) / rl.GetMusicTimeLength(music) * f32<-(screen_width - 40)

        if not pause:
            for index in range(0, max_circles):
                var circle = circles[max_circles - 1 - index]
                circle.alpha += circle.speed
                circle.radius += circle.speed * 10.0

                if circle.alpha > 1.0:
                    circle.speed *= -1.0

                if circle.alpha <= 0.0:
                    random_circle(addr(circles), max_circles - 1 - index, addr(colors))
                else:
                    circles[max_circles - 1 - index] = circle

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        for index in range(0, max_circles):
            let circle = circles[max_circles - 1 - index]
            rl.DrawCircleV(circle.position, circle.radius, rl.Fade(circle.color, circle.alpha))

        rl.DrawRectangle(20, screen_height - 32, screen_width - 40, 12, rl.LIGHTGRAY)
        rl.DrawRectangle(20, screen_height - 32, i32<-time_played, 12, rl.MAROON)
        rl.DrawRectangleLines(20, screen_height - 32, screen_width - 40, 12, rl.GRAY)

        rl.DrawRectangle(20, 20, 425, 145, rl.WHITE)
        rl.DrawRectangleLines(20, 20, 425, 145, rl.GRAY)
        rl.DrawText(restart_text, 40, 40, 20, rl.BLACK)
        rl.DrawText(pause_text, 40, 70, 20, rl.BLACK)
        rl.DrawText(speed_text, 40, 100, 20, rl.BLACK)
        rl.DrawText(rl.TextFormat(speed_format, pitch), 40, 130, 20, rl.MAROON)

    return 0
