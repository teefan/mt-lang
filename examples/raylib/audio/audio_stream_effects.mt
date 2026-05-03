module examples.raylib.audio.audio_stream_effects

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const music_path: cstr = c"../resources/country.mp3"
const playing_text: cstr = c"MUSIC SHOULD BE PLAYING!"
const restart_text: cstr = c"PRESS SPACE TO RESTART MUSIC"
const pause_text: cstr = c"PRESS P TO PAUSE/RESUME MUSIC"
const lpf_format: cstr = c"PRESS F TO TOGGLE LPF EFFECT: %s"
const delay_format: cstr = c"PRESS D TO TOGGLE DELAY EFFECT: %s"
const window_title: cstr = c"raylib [audio] example - stream effects"
const lpf_cutoff: f32 = 70.0 / 44100.0
const lpf_k: f32 = lpf_cutoff / (lpf_cutoff + 0.1591549431)

var delay_buffer: ptr[f32]? = null
var delay_buffer_size: u32 = 0
var delay_read_index: u32 = 2
var delay_write_index: u32 = 0
var low_pass_state: array[f32, 2]

def void_ptr_to_f32(value: ptr[void]) -> ptr[f32]:
    unsafe:
        return ptr[f32]<-value

def allocate_delay_buffer() -> void:
    delay_buffer_size = u32<-(48000 * 2)
    delay_read_index = 2
    delay_write_index = 0

    unsafe:
        delay_buffer = ptr[f32]?<-rl.MemAlloc(delay_buffer_size * u32<-sizeof(f32))
        if delay_buffer != null:
            let samples = ptr[f32]<-delay_buffer
            for index in range(0, i32<-delay_buffer_size):
                read(samples + index) = 0.0

def free_delay_buffer() -> void:
    if delay_buffer == null:
        return

    unsafe:
        rl.MemFree(ptr[f32]<-delay_buffer)

def audio_process_effect_lpf(buffer: ptr[void], frames: u32) -> void:
    let buffer_data = void_ptr_to_f32(buffer)
    let sample_count = i32<-frames * 2

    unsafe:
        var index = 0
        while index < sample_count:
            let left = read(buffer_data + index)
            let right = read(buffer_data + index + 1)

            low_pass_state[0] += lpf_k * (left - low_pass_state[0])
            low_pass_state[1] += lpf_k * (right - low_pass_state[1])
            read(buffer_data + index) = low_pass_state[0]
            read(buffer_data + index + 1) = low_pass_state[1]

            index += 2

def audio_process_effect_delay(buffer: ptr[void], frames: u32) -> void:
    if delay_buffer == null:
        return

    let buffer_data = void_ptr_to_f32(buffer)
    let sample_count = i32<-frames * 2

    unsafe:
        let delay_samples = ptr[f32]<-delay_buffer
        var index = 0

        while index < sample_count:
            let left_delay = read(delay_samples + i32<-delay_read_index)
            delay_read_index += 1
            let right_delay = read(delay_samples + i32<-delay_read_index)
            delay_read_index += 1

            if delay_read_index == delay_buffer_size:
                delay_read_index = 0

            let left_value = 0.5 * read(buffer_data + index) + 0.5 * left_delay
            let right_value = 0.5 * read(buffer_data + index + 1) + 0.5 * right_delay

            read(buffer_data + index) = left_value
            read(buffer_data + index + 1) = right_value

            read(delay_samples + i32<-delay_write_index) = left_value
            delay_write_index += 1
            read(delay_samples + i32<-delay_write_index) = right_value
            delay_write_index += 1

            if delay_write_index == delay_buffer_size:
                delay_write_index = 0

            index += 2

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.InitAudioDevice()
    defer rl.CloseAudioDevice()

    let music = rl.LoadMusicStream(music_path)
    defer rl.UnloadMusicStream(music)

    allocate_delay_buffer()
    defer free_delay_buffer()

    rl.PlayMusicStream(music)

    var time_played: f32 = 0.0
    var pause = false
    var enable_effect_lpf = false
    var enable_effect_delay = false

    rl.SetTargetFPS(60)

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

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_F):
            enable_effect_lpf = not enable_effect_lpf
            if enable_effect_lpf:
                rl.AttachAudioStreamProcessor(music.stream, audio_process_effect_lpf)
            else:
                rl.DetachAudioStreamProcessor(music.stream, audio_process_effect_lpf)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_D):
            enable_effect_delay = not enable_effect_delay
            if enable_effect_delay:
                rl.AttachAudioStreamProcessor(music.stream, audio_process_effect_delay)
            else:
                rl.DetachAudioStreamProcessor(music.stream, audio_process_effect_delay)

        time_played = rl.GetMusicTimePlayed(music) / rl.GetMusicTimeLength(music)
        if time_played > 1.0:
            time_played = 1.0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawText(playing_text, 245, 150, 20, rl.LIGHTGRAY)
        rl.DrawRectangle(200, 180, 400, 12, rl.LIGHTGRAY)
        rl.DrawRectangle(200, 180, i32<-(time_played * 400.0), 12, rl.MAROON)
        rl.DrawRectangleLines(200, 180, 400, 12, rl.GRAY)

        rl.DrawText(restart_text, 215, 230, 20, rl.LIGHTGRAY)
        rl.DrawText(pause_text, 208, 260, 20, rl.LIGHTGRAY)
        rl.DrawText(rl.TextFormat(lpf_format, if enable_effect_lpf: c"ON" else: c"OFF"), 200, 320, 20, rl.GRAY)
        rl.DrawText(rl.TextFormat(delay_format, if enable_effect_delay: c"ON" else: c"OFF"), 180, 350, 20, rl.GRAY)

    return 0