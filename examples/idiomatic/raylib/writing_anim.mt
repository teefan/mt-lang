module examples.idiomatic.raylib.writing_anim

import std.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const message: str = "This sample illustrates a text writing\nanimation effect! Check it out! ;)"


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea Writing Animation")
    defer rl.close_window()

    var frames_counter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_down(rl.KeyboardKey.KEY_SPACE):
            frames_counter += 8
        else:
            frames_counter += 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER):
            frames_counter = 0

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        rl.draw_text(rl.text_subtext(message, 0, frames_counter / 10), 210, 160, 20, rl.MAROON)
        rl.draw_text("PRESS [ENTER] to RESTART!", 240, 260, 20, rl.LIGHTGRAY)
        rl.draw_text("HOLD [SPACE] to SPEED UP!", 239, 300, 20, rl.LIGHTGRAY)

    return 0
