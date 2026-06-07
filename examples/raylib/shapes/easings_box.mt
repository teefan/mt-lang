import std.raylib.easing as ease
import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - easings box")
    defer rl.close_window()

    var rec = rl.Rectangle(x = float<-rl.get_screen_width() / 2.0, y = -100.0, width = 100.0, height = 100.0)
    var rotation: float = 0.0
    var alpha: float = 1.0
    var state = 0
    var frames_counter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if state == 0:
            frames_counter += 1
            rec.y = ease.elastic_out(float<-frames_counter, -100.0, float<-rl.get_screen_height() / 2.0 + 100.0, 120.0)

            if frames_counter >= 120:
                frames_counter = 0
                state = 1
        else if state == 1:
            frames_counter += 1
            rec.height = ease.bounce_out(float<-frames_counter, 100.0, -90.0, 120.0)
            rec.width = ease.bounce_out(float<-frames_counter, 100.0, float<-rl.get_screen_width(), 120.0)

            if frames_counter >= 120:
                frames_counter = 0
                state = 2
        else if state == 2:
            frames_counter += 1
            rotation = ease.quad_out(float<-frames_counter, 0.0, 270.0, 240.0)

            if frames_counter >= 240:
                frames_counter = 0
                state = 3
        else if state == 3:
            frames_counter += 1
            rec.height = ease.circ_out(float<-frames_counter, 10.0, float<-rl.get_screen_width(), 120.0)

            if frames_counter >= 120:
                frames_counter = 0
                state = 4
        else if state == 4:
            frames_counter += 1
            alpha = ease.sine_out(float<-frames_counter, 1.0, -1.0, 160.0)

            if frames_counter >= 160:
                frames_counter = 0
                state = 5

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            rec = rl.Rectangle(x = float<-rl.get_screen_width() / 2.0, y = -100.0, width = 100.0, height = 100.0)
            rotation = 0.0
            alpha = 1.0
            state = 0
            frames_counter = 0

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.draw_rectangle_pro(
            rec,
            rl.Vector2(x = rec.width / 2.0, y = rec.height / 2.0),
            rotation,
            rl.fade(rl.BLACK, alpha)
        )
        rl.draw_text("PRESS [SPACE] TO RESET BOX ANIMATION!", 10, rl.get_screen_height() - 25, 20, rl.LIGHTGRAY)
        rl.end_drawing()

    return 0
