module examples.raylib.core.core_input_actions

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - input actions"
const default_set_text: cstr = c"Current input set: WASD (default)"
const cursor_set_text: cstr = c"Current input set: Arrow keys"
const help_text: cstr = c"Use TAB key to toggles Actions keyset"
const gamepad_index: i32 = 0

enum ActionType: i32
    ACTION_UP = 1
    ACTION_DOWN = 2
    ACTION_LEFT = 3
    ACTION_RIGHT = 4
    ACTION_FIRE = 5

def is_action_pressed(action: ActionType, action_set: bool) -> bool:
    if action == ActionType.ACTION_UP:
        if action_set:
            return rl.IsKeyPressed(rl.KeyboardKey.KEY_UP) or rl.IsGamepadButtonPressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_UP)
        return rl.IsKeyPressed(rl.KeyboardKey.KEY_W) or rl.IsGamepadButtonPressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_UP)
    if action == ActionType.ACTION_DOWN:
        if action_set:
            return rl.IsKeyPressed(rl.KeyboardKey.KEY_DOWN) or rl.IsGamepadButtonPressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN)
        return rl.IsKeyPressed(rl.KeyboardKey.KEY_S) or rl.IsGamepadButtonPressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN)
    if action == ActionType.ACTION_LEFT:
        if action_set:
            return rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT) or rl.IsGamepadButtonPressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_LEFT)
        return rl.IsKeyPressed(rl.KeyboardKey.KEY_A) or rl.IsGamepadButtonPressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_LEFT)
    if action == ActionType.ACTION_RIGHT:
        if action_set:
            return rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT) or rl.IsGamepadButtonPressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_RIGHT)
        return rl.IsKeyPressed(rl.KeyboardKey.KEY_D) or rl.IsGamepadButtonPressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_RIGHT)
    if action_set:
        return rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE) or rl.IsGamepadButtonPressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN)
    return rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE) or rl.IsGamepadButtonPressed(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN)

def is_action_released(action: ActionType, action_set: bool) -> bool:
    if action == ActionType.ACTION_UP:
        if action_set:
            return rl.IsKeyReleased(rl.KeyboardKey.KEY_UP) or rl.IsGamepadButtonReleased(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_UP)
        return rl.IsKeyReleased(rl.KeyboardKey.KEY_W) or rl.IsGamepadButtonReleased(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_UP)
    if action == ActionType.ACTION_DOWN:
        if action_set:
            return rl.IsKeyReleased(rl.KeyboardKey.KEY_DOWN) or rl.IsGamepadButtonReleased(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN)
        return rl.IsKeyReleased(rl.KeyboardKey.KEY_S) or rl.IsGamepadButtonReleased(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN)
    if action == ActionType.ACTION_LEFT:
        if action_set:
            return rl.IsKeyReleased(rl.KeyboardKey.KEY_LEFT) or rl.IsGamepadButtonReleased(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_LEFT)
        return rl.IsKeyReleased(rl.KeyboardKey.KEY_A) or rl.IsGamepadButtonReleased(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_LEFT)
    if action == ActionType.ACTION_RIGHT:
        if action_set:
            return rl.IsKeyReleased(rl.KeyboardKey.KEY_RIGHT) or rl.IsGamepadButtonReleased(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_RIGHT)
        return rl.IsKeyReleased(rl.KeyboardKey.KEY_D) or rl.IsGamepadButtonReleased(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_RIGHT)
    if action_set:
        return rl.IsKeyReleased(rl.KeyboardKey.KEY_SPACE) or rl.IsGamepadButtonReleased(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN)
    return rl.IsKeyReleased(rl.KeyboardKey.KEY_SPACE) or rl.IsGamepadButtonReleased(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN)

def is_action_down(action: ActionType, action_set: bool) -> bool:
    if action == ActionType.ACTION_UP:
        if action_set:
            return rl.IsKeyDown(rl.KeyboardKey.KEY_UP) or rl.IsGamepadButtonDown(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_UP)
        return rl.IsKeyDown(rl.KeyboardKey.KEY_W) or rl.IsGamepadButtonDown(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_UP)
    if action == ActionType.ACTION_DOWN:
        if action_set:
            return rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN) or rl.IsGamepadButtonDown(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN)
        return rl.IsKeyDown(rl.KeyboardKey.KEY_S) or rl.IsGamepadButtonDown(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN)
    if action == ActionType.ACTION_LEFT:
        if action_set:
            return rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT) or rl.IsGamepadButtonDown(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_LEFT)
        return rl.IsKeyDown(rl.KeyboardKey.KEY_A) or rl.IsGamepadButtonDown(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_LEFT)
    if action == ActionType.ACTION_RIGHT:
        if action_set:
            return rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT) or rl.IsGamepadButtonDown(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_RIGHT)
        return rl.IsKeyDown(rl.KeyboardKey.KEY_D) or rl.IsGamepadButtonDown(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_RIGHT)
    if action_set:
        return rl.IsKeyDown(rl.KeyboardKey.KEY_SPACE) or rl.IsGamepadButtonDown(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN)
    return rl.IsKeyDown(rl.KeyboardKey.KEY_SPACE) or rl.IsGamepadButtonDown(gamepad_index, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN)

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var action_set = false
    var release_action = false
    var position = rl.Vector2(x = 400.0, y = 200.0)
    let size = rl.Vector2(x = 40.0, y = 40.0)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if is_action_down(ActionType.ACTION_UP, action_set):
            position.y -= 2.0
        if is_action_down(ActionType.ACTION_DOWN, action_set):
            position.y += 2.0
        if is_action_down(ActionType.ACTION_LEFT, action_set):
            position.x -= 2.0
        if is_action_down(ActionType.ACTION_RIGHT, action_set):
            position.x += 2.0
        if is_action_pressed(ActionType.ACTION_FIRE, action_set):
            position.x = 0.5 * screen_width - size.x / 2.0
            position.y = 0.5 * screen_height - size.y / 2.0

        release_action = is_action_released(ActionType.ACTION_FIRE, action_set)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_TAB):
            action_set = not action_set

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.GRAY)

        rl.DrawRectangleV(position, size, if release_action: rl.BLUE else: rl.RED)

        rl.DrawText(if action_set: cursor_set_text else: default_set_text, 10, 10, 20, rl.WHITE)
        rl.DrawText(help_text, 10, 50, 20, rl.GREEN)

    return 0