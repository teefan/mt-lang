import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const ACTION_UP: int = 1
const ACTION_DOWN: int = 2
const ACTION_LEFT: int = 3
const ACTION_RIGHT: int = 4
const ACTION_FIRE: int = 5
const MAX_ACTION: int = 6


struct ActionInput:
    key: int
    button: int


var gamepad_index: int = 0
var action_inputs: array[ActionInput, MAX_ACTION] = zero[array[ActionInput, MAX_ACTION]]


function is_action_pressed(action: int) -> bool:
    if action >= MAX_ACTION:
        return false

    return rl.is_key_pressed(rl.KeyboardKey<-action_inputs[action].key) or rl.is_gamepad_button_pressed(gamepad_index, rl.GamepadButton<-action_inputs[action].button)


function is_action_released(action: int) -> bool:
    if action >= MAX_ACTION:
        return false

    return rl.is_key_released(rl.KeyboardKey<-action_inputs[action].key) or rl.is_gamepad_button_released(gamepad_index, rl.GamepadButton<-action_inputs[action].button)


function is_action_down(action: int) -> bool:
    if action >= MAX_ACTION:
        return false

    return rl.is_key_down(rl.KeyboardKey<-action_inputs[action].key) or rl.is_gamepad_button_down(gamepad_index, rl.GamepadButton<-action_inputs[action].button)


function set_actions_default() -> void:
    action_inputs[ACTION_UP].key = int<-rl.KeyboardKey.KEY_W
    action_inputs[ACTION_DOWN].key = int<-rl.KeyboardKey.KEY_S
    action_inputs[ACTION_LEFT].key = int<-rl.KeyboardKey.KEY_A
    action_inputs[ACTION_RIGHT].key = int<-rl.KeyboardKey.KEY_D
    action_inputs[ACTION_FIRE].key = int<-rl.KeyboardKey.KEY_SPACE

    action_inputs[ACTION_UP].button = int<-rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_UP
    action_inputs[ACTION_DOWN].button = int<-rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN
    action_inputs[ACTION_LEFT].button = int<-rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_LEFT
    action_inputs[ACTION_RIGHT].button = int<-rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_RIGHT
    action_inputs[ACTION_FIRE].button = int<-rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN


function set_actions_cursor() -> void:
    action_inputs[ACTION_UP].key = int<-rl.KeyboardKey.KEY_UP
    action_inputs[ACTION_DOWN].key = int<-rl.KeyboardKey.KEY_DOWN
    action_inputs[ACTION_LEFT].key = int<-rl.KeyboardKey.KEY_LEFT
    action_inputs[ACTION_RIGHT].key = int<-rl.KeyboardKey.KEY_RIGHT
    action_inputs[ACTION_FIRE].key = int<-rl.KeyboardKey.KEY_SPACE

    action_inputs[ACTION_UP].button = int<-rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_UP
    action_inputs[ACTION_DOWN].button = int<-rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN
    action_inputs[ACTION_LEFT].button = int<-rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_LEFT
    action_inputs[ACTION_RIGHT].button = int<-rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_RIGHT
    action_inputs[ACTION_FIRE].button = int<-rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - input actions")
    defer rl.close_window()

    var action_set = 0
    set_actions_default()
    var release_action = false

    var position = rl.Vector2(x = 400.0, y = 200.0)
    let size = rl.Vector2(x = 40.0, y = 40.0)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        gamepad_index = 0

        if is_action_down(ACTION_UP):
            position.y -= 2.0
        if is_action_down(ACTION_DOWN):
            position.y += 2.0
        if is_action_down(ACTION_LEFT):
            position.x -= 2.0
        if is_action_down(ACTION_RIGHT):
            position.x += 2.0
        if is_action_pressed(ACTION_FIRE):
            position.x = ((float<-SCREEN_WIDTH) - size.x) / 2.0
            position.y = ((float<-SCREEN_HEIGHT) - size.y) / 2.0

        release_action = is_action_released(ACTION_FIRE)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_TAB):
            action_set = 1 - action_set
            if action_set == 0:
                set_actions_default()
            else:
                set_actions_cursor()

        rl.begin_drawing()
        rl.clear_background(rl.GRAY)

        var box_color = rl.RED
        if release_action:
            box_color = rl.BLUE
        rl.draw_rectangle_v(position, size, box_color)

        if action_set == 0:
            rl.draw_text("Current input set: WASD (default)", 10, 10, 20, rl.WHITE)
        else:
            rl.draw_text("Current input set: Arrow keys", 10, 10, 20, rl.WHITE)
        rl.draw_text("Use TAB key to toggle Actions keyset", 10, 50, 20, rl.GREEN)

        rl.end_drawing()

    return 0
