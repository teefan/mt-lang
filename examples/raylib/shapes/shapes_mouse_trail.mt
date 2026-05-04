module examples.raylib.shapes.shapes_mouse_trail

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const max_trail_length: i32 = 30
const window_title: cstr = c"raylib [shapes] example - mouse trail"
const help_text: cstr = c"Move the mouse to see the trail effect!"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var trail_positions = zero[array[rl.Vector2, 30]]()

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let mouse_position = rl.GetMousePosition()

        var index = max_trail_length - 1
        while index > 0:
            trail_positions[index] = trail_positions[index - 1]
            index -= 1

        trail_positions[0] = mouse_position

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)

        for index in 0..max_trail_length:
            if trail_positions[index].x != 0.0 or trail_positions[index].y != 0.0:
                let ratio: f32 = f32<-(max_trail_length - index) / f32<-max_trail_length
                let trail_color = rl.Fade(rl.SKYBLUE, ratio * 0.5 + 0.5)
                let trail_radius: f32 = 15.0 * ratio
                rl.DrawCircleV(trail_positions[index], trail_radius, trail_color)

        rl.DrawCircleV(mouse_position, 15.0, rl.WHITE)
        rl.DrawText(help_text, 10, screen_height - 30, 20, rl.LIGHTGRAY)

    return 0
