import std.math as math
import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const FRAME_CAPTURE_STRIDE: int = 5
const MAX_SINEWAVE_POINTS: int = 256
const HALF_SCREEN_HEIGHT: float = float<-(SCREEN_HEIGHT / 2)
const SINE_AMPLITUDE: float = 150.0
const CIRCLE_RADIUS: float = 30.0
const PI_TIMES_TWO: float = rl.PI * 2.0
const SINE_SCALE: float = PI_TIMES_TWO / 1.5
const FRAME_TIME_60: float = 1.0 / 60.0


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - screen recording")
    defer rl.close_window()

    var recording = false
    var capture_frame_counter: uint = 0
    var capture_index = 0
    var circle_position = rl.Vector2(x = 0.0, y = HALF_SCREEN_HEIGHT)
    var time_counter: float = 0.0
    var sine_points: array[rl.Vector2, MAX_SINEWAVE_POINTS] = zero[array[rl.Vector2, MAX_SINEWAVE_POINTS]]

    var index = 0
    while index < MAX_SINEWAVE_POINTS:
        sine_points[index].x = float<-index * float<-rl.get_screen_width() / 180.0
        sine_points[index].y = HALF_SCREEN_HEIGHT + SINE_AMPLITUDE * float<-math.sin(double<-(SINE_SCALE * FRAME_TIME_60 * float<-index))
        index += 1

    rl.set_target_fps(60)

    while not rl.window_should_close():
        time_counter += rl.get_frame_time()
        circle_position.x += float<-rl.get_screen_width() / 180.0
        circle_position.y = HALF_SCREEN_HEIGHT + SINE_AMPLITUDE * float<-math.sin(double<-(SINE_SCALE * time_counter))
        if circle_position.x > float<-SCREEN_WIDTH:
            circle_position.x = 0.0
            circle_position.y = HALF_SCREEN_HEIGHT
            time_counter = 0.0

        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT_CONTROL) and rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            recording = not recording
            capture_frame_counter = 0

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        var index = 0
        while index < MAX_SINEWAVE_POINTS - 1:
            rl.draw_line_v(sine_points[index], sine_points[index + 1], rl.MAROON)
            rl.draw_circle_v(sine_points[index], 3.0, rl.MAROON)
            index += 1

        rl.draw_circle_v(circle_position, CIRCLE_RADIUS, rl.RED)
        rl.draw_fps(10, 10)
        if recording:
            rl.draw_circle(30, rl.get_screen_height() - 20, 10.0, rl.MAROON)
            rl.draw_text("PNG RECORDING", 50, rl.get_screen_height() - 25, 10, rl.RED)
        rl.end_drawing()

        if recording:
            capture_frame_counter += 1
            if capture_frame_counter > uint<-FRAME_CAPTURE_STRIDE:
                rl.take_screenshot(rl.text_format(
                    "%sscreenrecording_%04i.png",
                    rl.get_application_directory(),
                    capture_index
                ))
                capture_index += 1
                capture_frame_counter = 0

    return 0
