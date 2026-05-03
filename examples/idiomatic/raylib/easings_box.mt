module examples.idiomatic.raylib.easings_box

import std.easing as ease
import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Easings Box")
    defer rl.close_window()

    let center_x = rl.get_screen_width() / 2.0
    let center_y_delta = f32<-(rl.get_screen_height() / 2 + 100)

    var rec = rl.Rectangle(x = center_x, y = -100.0, width = 100.0, height = 100.0)
    var rotation: f32 = 0.0
    var alpha: f32 = 1.0
    var state = 0
    var frames_counter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if state == 0:
            frames_counter += 1
            rec.y = ease.elastic_out(f32<-frames_counter, -100.0, center_y_delta, 120.0)

            if frames_counter >= 120:
                frames_counter = 0
                state = 1
        elif state == 1:
            frames_counter += 1
            rec.height = ease.bounce_out(f32<-frames_counter, 100.0, -90.0, 120.0)
            rec.width = ease.bounce_out(f32<-frames_counter, 100.0, f32<-rl.get_screen_width(), 120.0)

            if frames_counter >= 120:
                frames_counter = 0
                state = 2
        elif state == 2:
            frames_counter += 1
            rotation = ease.quad_out(f32<-frames_counter, 0.0, 270.0, 240.0)

            if frames_counter >= 240:
                frames_counter = 0
                state = 3
        elif state == 3:
            frames_counter += 1
            rec.height = ease.circ_out(f32<-frames_counter, 10.0, f32<-rl.get_screen_width(), 120.0)

            if frames_counter >= 120:
                frames_counter = 0
                state = 4
        elif state == 4:
            frames_counter += 1
            alpha = ease.sine_out(f32<-frames_counter, 1.0, -1.0, 160.0)

            if frames_counter >= 160:
                frames_counter = 0
                state = 5

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            rec = rl.Rectangle(x = center_x, y = -100.0, width = 100.0, height = 100.0)
            rotation = 0.0
            alpha = 1.0
            state = 0
            frames_counter = 0

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_rectangle_pro(rec, rl.Vector2(x = rec.width / 2.0, y = rec.height / 2.0), rotation, rl.fade(rl.BLACK, alpha))
        rl.draw_text("PRESS [SPACE] TO RESET BOX ANIMATION!", 10, rl.get_screen_height() - 25, 20, rl.LIGHTGRAY)

    return 0
