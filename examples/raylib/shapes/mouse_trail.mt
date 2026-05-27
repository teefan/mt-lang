import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_TRAIL_LENGTH: int = 30


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - mouse trail")
    defer rl.close_window()

    var trail_positions: array[rl.Vector2, MAX_TRAIL_LENGTH] = zero[array[rl.Vector2, MAX_TRAIL_LENGTH]]

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse_position = rl.get_mouse_position()

        var index = MAX_TRAIL_LENGTH - 1
        while index > 0:
            trail_positions[index] = trail_positions[index - 1]
            index -= 1
        trail_positions[0] = mouse_position

        rl.begin_drawing()
        rl.clear_background(rl.BLACK)

        index = 0
        while index < MAX_TRAIL_LENGTH:
            if trail_positions[index].x != 0.0 or trail_positions[index].y != 0.0:
                let ratio: float = float<-(MAX_TRAIL_LENGTH - index) / float<-MAX_TRAIL_LENGTH
                let trail_color = rl.fade(rl.SKYBLUE, ratio * 0.5 + 0.5)
                let trail_radius: float = 15.0 * ratio
                rl.draw_circle_v(trail_positions[index], trail_radius, trail_color)
            index += 1

        rl.draw_circle_v(mouse_position, 15.0, rl.WHITE)
        rl.draw_text("Move the mouse to see the trail effect!", 10, SCREEN_HEIGHT - 30, 20, rl.LIGHTGRAY)
        rl.end_drawing()

    return 0
