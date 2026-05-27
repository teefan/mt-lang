import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_TOUCH_POINTS: int = 10


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - input multitouch")
    defer rl.close_window()

    var touch_positions: array[rl.Vector2, MAX_TOUCH_POINTS] = zero[array[rl.Vector2, MAX_TOUCH_POINTS]]

    rl.set_target_fps(60)

    while not rl.window_should_close():
        var touch_count = rl.get_touch_point_count()
        if touch_count > MAX_TOUCH_POINTS:
            touch_count = MAX_TOUCH_POINTS

        var touch_index = 0
        while touch_index < touch_count:
            touch_positions[touch_index] = rl.get_touch_position(touch_index)
            touch_index += 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        touch_index = 0
        while touch_index < touch_count:
            let position = touch_positions[touch_index]
            if position.x > 0.0 and position.y > 0.0:
                rl.draw_circle_v(position, 34.0, rl.ORANGE)
                rl.draw_text(f"#{touch_index}", (int<-position.x) - 10, (int<-position.y) - 70, 40, rl.BLACK)

            touch_index += 1

        rl.draw_text("touch the screen at multiple locations to get multiple balls", 10, 10, 20, rl.DARKGRAY)
        rl.end_drawing()

    return 0
