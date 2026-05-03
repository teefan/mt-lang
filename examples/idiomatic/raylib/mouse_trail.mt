module examples.idiomatic.raylib.mouse_trail

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const max_trail_length: i32 = 30

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Mouse Trail")
    defer rl.close_window()

    var trail_positions = zero[array[rl.Vector2, 30]]()

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse_position = rl.get_mouse_position()

        var index = max_trail_length - 1
        while index > 0:
            trail_positions[index] = trail_positions[index - 1]
            index -= 1

        trail_positions[0] = mouse_position

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.BLACK)

        for index in range(0, max_trail_length):
            if trail_positions[index].x != 0.0 or trail_positions[index].y != 0.0:
                let ratio: f32 = f32<-(max_trail_length - index) / f32<-max_trail_length
                rl.draw_circle_v(trail_positions[index], 15.0 * ratio, rl.fade(rl.SKYBLUE, ratio * 0.5 + 0.5))

        rl.draw_circle_v(mouse_position, 15.0, rl.WHITE)
        rl.draw_text("Move the mouse to see the trail effect!", 10, screen_height - 30, 20, rl.LIGHTGRAY)

    return 0