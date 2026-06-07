import std.raylib.easing as ease
import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const RECS_WIDTH: float = 50.0
const RECS_HEIGHT: float = 50.0
const MAX_RECS_X: int = SCREEN_WIDTH / 50
const MAX_RECS_Y: int = SCREEN_HEIGHT / 50
const TOTAL_RECS: int = MAX_RECS_X * MAX_RECS_Y
const PLAY_TIME_IN_FRAMES: float = 240.0


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - easings rectangles")
    defer rl.close_window()

    var recs: array[rl.Rectangle, TOTAL_RECS] = zero[array[rl.Rectangle, TOTAL_RECS]]

    var y = 0
    while y < MAX_RECS_Y:
        var x = 0
        while x < MAX_RECS_X:
            let index = y * MAX_RECS_X + x
            recs[index].x = RECS_WIDTH / 2.0 + RECS_WIDTH * float<-x
            recs[index].y = RECS_HEIGHT / 2.0 + RECS_HEIGHT * float<-y
            recs[index].width = RECS_WIDTH
            recs[index].height = RECS_HEIGHT
            x += 1
        y += 1

    var rotation: float = 0.0
    var frames_counter = 0
    var state = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if state == 0:
            frames_counter += 1

            var index = 0
            while index < TOTAL_RECS:
                recs[index].height = ease.circ_out(
                    float<-frames_counter,
                    RECS_HEIGHT,
                    -RECS_HEIGHT,
                    PLAY_TIME_IN_FRAMES
                )
                recs[index].width = ease.circ_out(float<-frames_counter, RECS_WIDTH, -RECS_WIDTH, PLAY_TIME_IN_FRAMES)

                if recs[index].height < 0.0:
                    recs[index].height = 0.0
                if recs[index].width < 0.0:
                    recs[index].width = 0.0
                if recs[index].height == 0.0 and recs[index].width == 0.0:
                    state = 1

                rotation = ease.linear_in(float<-frames_counter, 0.0, 360.0, PLAY_TIME_IN_FRAMES)
                index += 1
        else if state == 1 and rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            frames_counter = 0

            var index = 0
            while index < TOTAL_RECS:
                recs[index].height = RECS_HEIGHT
                recs[index].width = RECS_WIDTH
                index += 1

            state = 0

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        if state == 0:
            var index = 0
            while index < TOTAL_RECS:
                rl.draw_rectangle_pro(
                    recs[index],
                    rl.Vector2(x = recs[index].width / 2.0, y = recs[index].height / 2.0),
                    rotation,
                    rl.RED
                )
                index += 1
        else:
            rl.draw_text("PRESS [SPACE] TO PLAY AGAIN!", 240, 200, 20, rl.GRAY)

        rl.end_drawing()

    return 0
