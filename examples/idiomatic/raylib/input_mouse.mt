module examples.idiomatic.raylib.input_mouse

import std.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const ball_radius: float = 40.0


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea Input Mouse")
    defer rl.close_window()

    var ball_position = rl.Vector2(x = -100.0, y = -100.0)
    var ball_color = rl.DARKBLUE

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_H):
            if rl.is_cursor_hidden():
                rl.show_cursor()
            else:
                rl.hide_cursor()

        ball_position = rl.get_mouse_position()

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            ball_color = rl.MAROON
        elif rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_MIDDLE):
            ball_color = rl.LIME
        elif rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            ball_color = rl.DARKBLUE
        elif rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_SIDE):
            ball_color = rl.PURPLE
        elif rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_EXTRA):
            ball_color = rl.YELLOW
        elif rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_FORWARD):
            ball_color = rl.ORANGE
        elif rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_BACK):
            ball_color = rl.BEIGE

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_circle_v(ball_position, ball_radius, ball_color)
        rl.draw_text("move ball with mouse and click mouse button to change color", 10, 10, 20, rl.DARKGRAY)
        rl.draw_text("Press 'H' to toggle cursor visibility", 10, 30, 20, rl.DARKGRAY)

        if rl.is_cursor_hidden():
            rl.draw_text("CURSOR HIDDEN", 20, 60, 20, rl.RED)
        else:
            rl.draw_text("CURSOR VISIBLE", 20, 60, 20, rl.LIME)

    return 0
