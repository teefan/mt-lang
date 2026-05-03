module examples.raylib.shapes.shapes_easings_rectangles

import std.c.libm as math
import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const recs_width: i32 = 50
const recs_height: i32 = 50
const max_recs_x: i32 = screen_width / recs_width
const max_recs_y: i32 = screen_height / recs_height
const rec_count: i32 = max_recs_x * max_recs_y
const play_time_in_frames: i32 = 240
const window_title: cstr = c"raylib [shapes] example - easings rectangles"
const replay_text: cstr = c"PRESS [SPACE] TO PLAY AGAIN!"

def ease_linear_in(t: f32, b: f32, c: f32, d: f32) -> f32:
    return c * t / d + b

def ease_circ_out(t: f32, b: f32, c: f32, d: f32) -> f32:
    let normalized = t / d - 1.0
    return c * math.sqrtf(1.0 - normalized * normalized) + b

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var recs = zero[array[rl.Rectangle, 144]]()

    for y in range(0, max_recs_y):
        for x in range(0, max_recs_x):
            let index = y * max_recs_x + x
            recs[index].x = recs_width / 2.0 + recs_width * x
            recs[index].y = recs_height / 2.0 + recs_height * y
            recs[index].width = recs_width
            recs[index].height = recs_height

    var rotation: f32 = 0.0
    var frames_counter = 0
    var state = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if state == 0:
            frames_counter += 1

            for index in range(0, rec_count):
                recs[index].height = ease_circ_out(f32<-frames_counter, f32<-recs_height, -f32<-recs_height, f32<-play_time_in_frames)
                recs[index].width = ease_circ_out(f32<-frames_counter, f32<-recs_width, -f32<-recs_width, f32<-play_time_in_frames)

                if recs[index].height < 0.0:
                    recs[index].height = 0.0
                if recs[index].width < 0.0:
                    recs[index].width = 0.0

                if recs[index].height == 0.0 and recs[index].width == 0.0:
                    state = 1

                rotation = ease_linear_in(f32<-frames_counter, 0.0, 360.0, f32<-play_time_in_frames)
        elif state == 1 and rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            frames_counter = 0

            for index in range(0, rec_count):
                recs[index].height = recs_height
                recs[index].width = recs_width

            state = 0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        if state == 0:
            for index in range(0, rec_count):
                rl.DrawRectanglePro(recs[index], rl.Vector2(x = recs[index].width / 2.0, y = recs[index].height / 2.0), rotation, rl.RED)
        elif state == 1:
            rl.DrawText(replay_text, 240, 200, 20, rl.GRAY)

    return 0