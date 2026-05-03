module examples.idiomatic.raylib.easings_rectangles

import std.easing as ease
import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const recs_width: i32 = 50
const recs_height: i32 = 50
const max_recs_x: i32 = screen_width / recs_width
const max_recs_y: i32 = screen_height / recs_height
const rec_count: i32 = max_recs_x * max_recs_y
const play_time_in_frames: i32 = 240


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Easings Rectangles")
    defer rl.close_window()

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

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if state == 0:
            frames_counter += 1

            for index in range(0, rec_count):
                recs[index].height = ease.circ_out(f32<-frames_counter, f32<-recs_height, -f32<-recs_height, f32<-play_time_in_frames)
                recs[index].width = ease.circ_out(f32<-frames_counter, f32<-recs_width, -f32<-recs_width, f32<-play_time_in_frames)

                if recs[index].height < 0.0:
                    recs[index].height = 0.0
                if recs[index].width < 0.0:
                    recs[index].width = 0.0

                if recs[index].height == 0.0 and recs[index].width == 0.0:
                    state = 1

                rotation = ease.linear_in(f32<-frames_counter, 0.0, 360.0, f32<-play_time_in_frames)
        elif state == 1 and rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            frames_counter = 0

            for index in range(0, rec_count):
                recs[index].height = recs_height
                recs[index].width = recs_width

            state = 0

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        if state == 0:
            for index in range(0, rec_count):
                rl.draw_rectangle_pro(recs[index], rl.Vector2(x = recs[index].width / 2.0, y = recs[index].height / 2.0), rotation, rl.RED)
        elif state == 1:
            rl.draw_text("PRESS [SPACE] TO PLAY AGAIN!", 240, 200, 20, rl.GRAY)

    return 0
