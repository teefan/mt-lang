module examples.idiomatic.raylib.basic_window

import std.raylib as rl

const screen_width: int = 960
const screen_height: int = 540
const accent_radius: float = 48.0


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea")
    defer rl.close_window()

    let accent = rl.Vector2(x = screen_width / 2.0, y = screen_height / 2.0)
    let panel = rl.Rectangle(x = 160.0, y = 120.0, width = 640.0, height = 300.0)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_rectangle_rec(panel, rl.SKYBLUE)
        rl.draw_circle_v(accent, accent_radius, rl.MAROON)

    return 0
