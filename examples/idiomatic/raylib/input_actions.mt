module examples.idiomatic.raylib.input_actions

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const gamepad_index: i32 = 0

enum ActionType: i32
    ACTION_UP = 1
    ACTION_DOWN = 2
    ACTION_LEFT = 3
    ACTION_RIGHT = 4
    ACTION_FIRE = 5

def is_action_pressed(action: ActionType, cursor_set: bool) -> bool:
    if action == ActionType.ACTION_UP:
        if cursor_set:
            return rl.is_key_pressed(rl.KeyboardKey.KEY_UP) or rl.is_gamepad_button_pressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_UP)
        return rl.is_key_pressed(rl.KeyboardKey.KEY_W) or rl.is_gamepad_button_pressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_UP)
    if action == ActionType.ACTION_DOWN:
        if cursor_set:
            return rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN) or rl.is_gamepad_button_pressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN)
        return rl.is_key_pressed(rl.KeyboardKey.KEY_S) or rl.is_gamepad_button_pressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN)
    if action == ActionType.ACTION_LEFT:
        if cursor_set:
            return rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT) or rl.is_gamepad_button_pressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_LEFT)
        return rl.is_key_pressed(rl.KeyboardKey.KEY_A) or rl.is_gamepad_button_pressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_LEFT)
    if action == ActionType.ACTION_RIGHT:
        if cursor_set:
            return rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT) or rl.is_gamepad_button_pressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_RIGHT)
        return rl.is_key_pressed(rl.KeyboardKey.KEY_D) or rl.is_gamepad_button_pressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_RIGHT)
    if cursor_set:
        return rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE) or rl.is_gamepad_button_pressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN)
    return rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE) or rl.is_gamepad_button_pressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN)

def is_action_released(action: ActionType, cursor_set: bool) -> bool:
    if action == ActionType.ACTION_UP:
        if cursor_set:
            return rl.is_key_released(rl.KeyboardKey.KEY_UP) or rl.is_gamepad_button_released(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_UP)
        return rl.is_key_released(rl.KeyboardKey.KEY_W) or rl.is_gamepad_button_released(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_UP)
    if action == ActionType.ACTION_DOWN:
        if cursor_set:
            return rl.is_key_released(rl.KeyboardKey.KEY_DOWN) or rl.is_gamepad_button_released(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN)
        return rl.is_key_released(rl.KeyboardKey.KEY_S) or rl.is_gamepad_button_released(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN)
    if action == ActionType.ACTION_LEFT:
        if cursor_set:
            return rl.is_key_released(rl.KeyboardKey.KEY_LEFT) or rl.is_gamepad_button_released(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_LEFT)
        return rl.is_key_released(rl.KeyboardKey.KEY_A) or rl.is_gamepad_button_released(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_LEFT)
    if action == ActionType.ACTION_RIGHT:
        if cursor_set:
            return rl.is_key_released(rl.KeyboardKey.KEY_RIGHT) or rl.is_gamepad_button_released(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_RIGHT)
        return rl.is_key_released(rl.KeyboardKey.KEY_D) or rl.is_gamepad_button_released(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_RIGHT)
    if cursor_set:
        return rl.is_key_released(rl.KeyboardKey.KEY_SPACE) or rl.is_gamepad_button_released(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN)
    return rl.is_key_released(rl.KeyboardKey.KEY_SPACE) or rl.is_gamepad_button_released(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN)

def is_action_down(action: ActionType, cursor_set: bool) -> bool:
    if action == ActionType.ACTION_UP:
        if cursor_set:
            return rl.is_key_down(rl.KeyboardKey.KEY_UP) or rl.is_gamepad_button_down(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_UP)
        return rl.is_key_down(rl.KeyboardKey.KEY_W) or rl.is_gamepad_button_down(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_UP)
    if action == ActionType.ACTION_DOWN:
        if cursor_set:
            return rl.is_key_down(rl.KeyboardKey.KEY_DOWN) or rl.is_gamepad_button_down(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN)
        return rl.is_key_down(rl.KeyboardKey.KEY_S) or rl.is_gamepad_button_down(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN)
    if action == ActionType.ACTION_LEFT:
        if cursor_set:
            return rl.is_key_down(rl.KeyboardKey.KEY_LEFT) or rl.is_gamepad_button_down(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_LEFT)
        return rl.is_key_down(rl.KeyboardKey.KEY_A) or rl.is_gamepad_button_down(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_LEFT)
    if action == ActionType.ACTION_RIGHT:
        if cursor_set:
            return rl.is_key_down(rl.KeyboardKey.KEY_RIGHT) or rl.is_gamepad_button_down(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_RIGHT)
        return rl.is_key_down(rl.KeyboardKey.KEY_D) or rl.is_gamepad_button_down(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_RIGHT)
    if cursor_set:
        return rl.is_key_down(rl.KeyboardKey.KEY_SPACE) or rl.is_gamepad_button_down(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN)
    return rl.is_key_down(rl.KeyboardKey.KEY_SPACE) or rl.is_gamepad_button_down(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN)

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Input Actions")
    defer rl.close_window()

    var cursor_set = false
    var release_action = false
    var position = rl.Vector2(x = 400.0, y = 200.0)
    let size = rl.Vector2(x = 40.0, y = 40.0)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if is_action_down(ActionType.ACTION_UP, cursor_set):
            position.y -= 2.0
        if is_action_down(ActionType.ACTION_DOWN, cursor_set):
            position.y += 2.0
        if is_action_down(ActionType.ACTION_LEFT, cursor_set):
            position.x -= 2.0
        if is_action_down(ActionType.ACTION_RIGHT, cursor_set):
            position.x += 2.0
        if is_action_pressed(ActionType.ACTION_FIRE, cursor_set):
            position.x = 0.5 * screen_width - size.x / 2.0
            position.y = 0.5 * screen_height - size.y / 2.0

        release_action = is_action_released(ActionType.ACTION_FIRE, cursor_set)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_TAB):
            cursor_set = not cursor_set

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.GRAY)
        rl.draw_rectangle_v(position, size, if release_action: rl.BLUE else: rl.RED)
        if cursor_set:
            rl.draw_text("Current input set: Arrow keys", 10, 10, 20, rl.WHITE)
        else:
            rl.draw_text("Current input set: WASD (default)", 10, 10, 20, rl.WHITE)
        rl.draw_text("Use TAB key to toggle actions keyset", 10, 50, 20, rl.GREEN)

    return 0