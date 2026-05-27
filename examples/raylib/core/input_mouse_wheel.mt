import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const SCROLL_SPEED: int = 4


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - input mouse wheel")
    defer rl.close_window()

    var box_position_y = (SCREEN_HEIGHT / 2) - 40

    rl.set_target_fps(60)

    while not rl.window_should_close():
        box_position_y -= int<-(rl.get_mouse_wheel_move() * float<-SCROLL_SPEED)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_rectangle((SCREEN_WIDTH / 2) - 40, box_position_y, 80, 80, rl.MAROON)
        rl.draw_text("Use mouse wheel to move the cube up and down!", 10, 10, 20, rl.GRAY)
        rl.draw_text(f"Box position Y: #{box_position_y}", 10, 40, 20, rl.LIGHTGRAY)

        rl.end_drawing()

    return 0
