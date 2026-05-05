module examples.raylib.core.core_input_virtual_controls

import std.c.raylib as rl
import std.math as math

const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [core] example - input virtual controls"
const help_text: cstr = c"move the player with D-Pad buttons"

enum PadButton: int
    BUTTON_NONE = -1
    BUTTON_UP = 0
    BUTTON_LEFT = 1
    BUTTON_RIGHT = 2
    BUTTON_DOWN = 3


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let pad_position = rl.Vector2(x = 100.0, y = 350.0)
    let button_radius: float = 30.0
    let player_speed: float = 75.0

    let button_up = rl.Vector2(x = pad_position.x, y = pad_position.y - button_radius * 1.5)
    let button_left = rl.Vector2(x = pad_position.x - button_radius * 1.5, y = pad_position.y)
    let button_right = rl.Vector2(x = pad_position.x + button_radius * 1.5, y = pad_position.y)
    let button_down = rl.Vector2(x = pad_position.x, y = pad_position.y + button_radius * 1.5)

    var pressed_button = PadButton.BUTTON_NONE
    var input_position = rl.Vector2(x = 0.0, y = 0.0)
    var player_position = rl.Vector2(x = 0.5 * screen_width, y = 0.5 * screen_height)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.GetTouchPointCount() > 0:
            input_position = rl.GetTouchPosition(0)
        else:
            input_position = rl.GetMousePosition()

        pressed_button = PadButton.BUTTON_NONE

        if rl.GetTouchPointCount() > 0 or (rl.GetTouchPointCount() == 0 and rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT)):
            let dist_up = math.abs(button_up.x - input_position.x) + math.abs(button_up.y - input_position.y)
            let dist_left = math.abs(button_left.x - input_position.x) + math.abs(button_left.y - input_position.y)
            let dist_right = math.abs(button_right.x - input_position.x) + math.abs(button_right.y - input_position.y)
            let dist_down = math.abs(button_down.x - input_position.x) + math.abs(button_down.y - input_position.y)

            if dist_up < button_radius:
                pressed_button = PadButton.BUTTON_UP
            elif dist_left < button_radius:
                pressed_button = PadButton.BUTTON_LEFT
            elif dist_right < button_radius:
                pressed_button = PadButton.BUTTON_RIGHT
            elif dist_down < button_radius:
                pressed_button = PadButton.BUTTON_DOWN

        if pressed_button == PadButton.BUTTON_UP:
            player_position.y -= player_speed * rl.GetFrameTime()
        elif pressed_button == PadButton.BUTTON_LEFT:
            player_position.x -= player_speed * rl.GetFrameTime()
        elif pressed_button == PadButton.BUTTON_RIGHT:
            player_position.x += player_speed * rl.GetFrameTime()
        elif pressed_button == PadButton.BUTTON_DOWN:
            player_position.y += player_speed * rl.GetFrameTime()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawCircleV(player_position, 50.0, rl.MAROON)

        rl.DrawCircleV(button_up, button_radius, if pressed_button == PadButton.BUTTON_UP: rl.DARKGRAY else: rl.BLACK)
        rl.DrawTriangle(
            rl.Vector2(x = button_up.x, y = button_up.y - 12.0),
            rl.Vector2(x = button_up.x - 9.0, y = button_up.y + 9.0),
            rl.Vector2(x = button_up.x + 9.0, y = button_up.y + 9.0),
            rl.YELLOW,
        )

        rl.DrawCircleV(button_left, button_radius, if pressed_button == PadButton.BUTTON_LEFT: rl.DARKGRAY else: rl.BLACK)
        rl.DrawTriangle(
            rl.Vector2(x = button_left.x + 9.0, y = button_left.y - 9.0),
            rl.Vector2(x = button_left.x - 12.0, y = button_left.y),
            rl.Vector2(x = button_left.x + 9.0, y = button_left.y + 9.0),
            rl.BLUE,
        )

        rl.DrawCircleV(button_right, button_radius, if pressed_button == PadButton.BUTTON_RIGHT: rl.DARKGRAY else: rl.BLACK)
        rl.DrawTriangle(
            rl.Vector2(x = button_right.x + 12.0, y = button_right.y),
            rl.Vector2(x = button_right.x - 9.0, y = button_right.y - 9.0),
            rl.Vector2(x = button_right.x - 9.0, y = button_right.y + 9.0),
            rl.RED,
        )

        rl.DrawCircleV(button_down, button_radius, if pressed_button == PadButton.BUTTON_DOWN: rl.DARKGRAY else: rl.BLACK)
        rl.DrawTriangle(
            rl.Vector2(x = button_down.x - 9.0, y = button_down.y - 9.0),
            rl.Vector2(x = button_down.x, y = button_down.y + 12.0),
            rl.Vector2(x = button_down.x + 9.0, y = button_down.y - 9.0),
            rl.GREEN,
        )

        rl.DrawText(help_text, 10, 10, 20, rl.DARKGRAY)

    return 0
