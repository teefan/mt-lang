import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const CIRCLE_SPEED: float = 200.0
const ONE_FLOAT: float = 1.0
const ZERO_FLOAT: float = 0.0
const MILLISECONDS_PER_SECOND: float = 1000.0


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - custom frame control")

    var previous_time = rl.get_time()
    var current_time = 0.0
    var update_draw_time = 0.0
    var wait_time = 0.0
    var delta_time: float = ZERO_FLOAT

    var time_counter: float = ZERO_FLOAT
    var position: float = ZERO_FLOAT
    var pause = false
    var target_fps = 60

    while not rl.window_should_close():
        rl.poll_input_events()

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            pause = not pause

        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            target_fps += 20
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            target_fps -= 20

        if target_fps < 0:
            target_fps = 0

        if not pause:
            position += CIRCLE_SPEED * delta_time
            if position >= float<-rl.get_screen_width():
                position = ZERO_FLOAT
            time_counter += delta_time

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        var stripe = 0
        while stripe < rl.get_screen_width() / 200:
            rl.draw_rectangle(200 * stripe, 0, 1, rl.get_screen_height(), rl.SKYBLUE)
            stripe += 1

        let elapsed_text = rl.text_format("%03.0f ms", time_counter * MILLISECONDS_PER_SECOND)
        let position_text = rl.text_format("PosX: %03.0f", position)
        let target_fps_text = rl.text_format("TARGET FPS: %i", target_fps)

        rl.draw_circle(int<-position, (rl.get_screen_height() / 2) - 25, 50.0, rl.RED)
        rl.draw_text(elapsed_text, int<-position - 40, (rl.get_screen_height() / 2) - 100, 20, rl.MAROON)
        rl.draw_text(position_text, int<-position - 50, (rl.get_screen_height() / 2) + 40, 20, rl.BLACK)
        rl.draw_text("Circle is moving at a constant 200 pixels/sec,\nindependently of the frame rate.", 10, 10, 20, rl.DARKGRAY)
        rl.draw_text("PRESS SPACE to PAUSE MOVEMENT", 10, rl.get_screen_height() - 60, 20, rl.GRAY)
        rl.draw_text("PRESS UP | DOWN to CHANGE TARGET FPS", 10, rl.get_screen_height() - 30, 20, rl.GRAY)
        rl.draw_text(target_fps_text, rl.get_screen_width() - 220, 10, 20, rl.LIME)
        if delta_time != ZERO_FLOAT:
            let current_fps_text = rl.text_format("CURRENT FPS: %i", int<-(ONE_FLOAT / delta_time))
            rl.draw_text(current_fps_text, rl.get_screen_width() - 220, 40, 20, rl.GREEN)
        rl.end_drawing()

        rl.swap_screen_buffer()

        current_time = rl.get_time()
        update_draw_time = current_time - previous_time

        if target_fps > 0:
            wait_time = (1.0 / double<-target_fps) - update_draw_time
            if wait_time > 0.0:
                rl.wait_time(wait_time)
                current_time = rl.get_time()
                delta_time = float<-(current_time - previous_time)
            else:
                delta_time = float<-update_draw_time
        else:
            delta_time = float<-update_draw_time

        previous_time = current_time

    rl.close_window()
    return 0
