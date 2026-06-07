import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [text] example - writing anim")
    defer rl.close_window()

    let message = "This sample illustrates a text writing\nanimation effect! Check it out! ;)"
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
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text(rl.text_subtext(message, 0, frames_counter / 10), 210, 160, 20, rl.MAROON)
        rl.draw_text("PRESS [ENTER] to RESTART!", 240, 260, 20, rl.LIGHTGRAY)
        rl.draw_text("HOLD [SPACE] to SPEED UP!", 239, 300, 20, rl.LIGHTGRAY)

        rl.end_drawing()

    return 0
