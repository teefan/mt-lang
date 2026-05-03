module examples.raylib.core.core_input_gamepad

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - input gamepad"
const xbox_alias_1: cstr = c"xbox"
const xbox_alias_2: cstr = c"x-box"
const ps_alias_1: cstr = c"playstation"
const ps_alias_2: cstr = c"sony"
const ps3_texture_path: cstr = c"../resources/ps3.png"
const xbox_texture_path: cstr = c"../resources/xbox.png"
const left_stick_deadzone_x: f32 = 0.1
const left_stick_deadzone_y: f32 = 0.1
const right_stick_deadzone_x: f32 = 0.1
const right_stick_deadzone_y: f32 = 0.1
const left_trigger_deadzone: f32 = -0.9
const right_trigger_deadzone: f32 = -0.9


def gamepad_name_matches(gamepad_name: cstr, alias_one: cstr, alias_two: cstr) -> bool:
    let lower_gamepad_name = rl.TextToLower(gamepad_name)
    unsafe:
        let lower_gamepad_name_cstr = cstr<-lower_gamepad_name
        return rl.TextFindIndex(lower_gamepad_name_cstr, alias_one) > -1 or rl.TextFindIndex(lower_gamepad_name_cstr, alias_two) > -1


def draw_stick(center_x: i32, center_y: i32, outer_radius: f32, inner_radius: f32, stick_x: f32, stick_y: f32, pressed: bool) -> void:
    var stick_color = rl.BLACK
    if pressed:
        stick_color = rl.RED

    rl.DrawCircle(center_x, center_y, outer_radius, rl.BLACK)
    rl.DrawCircle(center_x, center_y, inner_radius, rl.LIGHTGRAY)
    rl.DrawCircle(center_x + i32<-(stick_x * 20.0), center_y + i32<-(stick_y * 20.0), 25.0, stick_color)
    return


def draw_trigger_bar(pos_x: i32, pos_y: i32, trigger_value: f32) -> void:
    rl.DrawRectangle(pos_x, pos_y, 15, 70, rl.GRAY)
    rl.DrawRectangle(pos_x, pos_y, 15, i32<-(((1.0 + trigger_value) / 2.0) * 70.0), rl.RED)
    return


def draw_xbox_gamepad(gamepad: i32, texture: rl.Texture2D, left_stick_x: f32, left_stick_y: f32, right_stick_x: f32, right_stick_y: f32, left_trigger: f32, right_trigger: f32) -> void:
    rl.DrawTexture(texture, 0, 0, rl.DARKGRAY)

    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_MIDDLE):
        rl.DrawCircle(394, 89, 19.0, rl.RED)

    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_MIDDLE_RIGHT):
        rl.DrawCircle(436, 150, 9.0, rl.RED)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_MIDDLE_LEFT):
        rl.DrawCircle(352, 150, 9.0, rl.RED)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_LEFT):
        rl.DrawCircle(501, 151, 15.0, rl.BLUE)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN):
        rl.DrawCircle(536, 187, 15.0, rl.LIME)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_RIGHT):
        rl.DrawCircle(572, 151, 15.0, rl.MAROON)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_UP):
        rl.DrawCircle(536, 115, 15.0, rl.GOLD)

    rl.DrawRectangle(317, 202, 19, 71, rl.BLACK)
    rl.DrawRectangle(293, 228, 69, 19, rl.BLACK)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_UP):
        rl.DrawRectangle(317, 202, 19, 26, rl.RED)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN):
        rl.DrawRectangle(317, 247, 19, 26, rl.RED)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_LEFT):
        rl.DrawRectangle(292, 228, 25, 19, rl.RED)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_RIGHT):
        rl.DrawRectangle(336, 228, 26, 19, rl.RED)

    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_TRIGGER_1):
        rl.DrawCircle(259, 61, 20.0, rl.RED)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_TRIGGER_1):
        rl.DrawCircle(536, 61, 20.0, rl.RED)

    draw_stick(259, 152, 39.0, 34.0, left_stick_x, left_stick_y, rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_THUMB))
    draw_stick(461, 237, 38.0, 33.0, right_stick_x, right_stick_y, rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_THUMB))
    draw_trigger_bar(170, 30, left_trigger)
    draw_trigger_bar(604, 30, right_trigger)
    return


def draw_ps_gamepad(gamepad: i32, texture: rl.Texture2D, left_stick_x: f32, left_stick_y: f32, right_stick_x: f32, right_stick_y: f32, left_trigger: f32, right_trigger: f32) -> void:
    rl.DrawTexture(texture, 0, 0, rl.DARKGRAY)

    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_MIDDLE):
        rl.DrawCircle(396, 222, 13.0, rl.RED)

    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_MIDDLE_LEFT):
        rl.DrawRectangle(328, 170, 32, 13, rl.RED)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_MIDDLE_RIGHT):
        rl.DrawTriangle(rl.Vector2(x = 436.0, y = 168.0), rl.Vector2(x = 436.0, y = 185.0), rl.Vector2(x = 464.0, y = 177.0), rl.RED)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_UP):
        rl.DrawCircle(557, 144, 13.0, rl.LIME)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_RIGHT):
        rl.DrawCircle(586, 173, 13.0, rl.RED)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN):
        rl.DrawCircle(557, 203, 13.0, rl.VIOLET)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_LEFT):
        rl.DrawCircle(527, 173, 13.0, rl.PINK)

    rl.DrawRectangle(225, 132, 24, 84, rl.BLACK)
    rl.DrawRectangle(195, 161, 84, 25, rl.BLACK)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_UP):
        rl.DrawRectangle(225, 132, 24, 29, rl.RED)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN):
        rl.DrawRectangle(225, 186, 24, 30, rl.RED)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_LEFT):
        rl.DrawRectangle(195, 161, 30, 25, rl.RED)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_RIGHT):
        rl.DrawRectangle(249, 161, 30, 25, rl.RED)

    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_TRIGGER_1):
        rl.DrawCircle(239, 82, 20.0, rl.RED)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_TRIGGER_1):
        rl.DrawCircle(557, 82, 20.0, rl.RED)

    draw_stick(319, 255, 35.0, 31.0, left_stick_x, left_stick_y, rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_THUMB))
    draw_stick(475, 255, 35.0, 31.0, right_stick_x, right_stick_y, rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_THUMB))
    draw_trigger_bar(169, 48, left_trigger)
    draw_trigger_bar(611, 48, right_trigger)
    return


def draw_generic_gamepad(gamepad: i32, left_stick_x: f32, left_stick_y: f32, right_stick_x: f32, right_stick_y: f32, left_trigger: f32, right_trigger: f32) -> void:
    rl.DrawRectangleRounded(rl.Rectangle(x = 175.0, y = 110.0, width = 460.0, height = 220.0), 0.3, 16, rl.DARKGRAY)

    rl.DrawCircle(365, 170, 12.0, rl.RAYWHITE)
    rl.DrawCircle(405, 170, 12.0, rl.RAYWHITE)
    rl.DrawCircle(445, 170, 12.0, rl.RAYWHITE)
    rl.DrawCircle(516, 191, 17.0, rl.RAYWHITE)
    rl.DrawCircle(551, 227, 17.0, rl.RAYWHITE)
    rl.DrawCircle(587, 191, 17.0, rl.RAYWHITE)
    rl.DrawCircle(551, 155, 17.0, rl.RAYWHITE)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_MIDDLE_LEFT):
        rl.DrawCircle(365, 170, 10.0, rl.RED)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_MIDDLE):
        rl.DrawCircle(405, 170, 10.0, rl.GREEN)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_MIDDLE_RIGHT):
        rl.DrawCircle(445, 170, 10.0, rl.BLUE)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_LEFT):
        rl.DrawCircle(516, 191, 15.0, rl.GOLD)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN):
        rl.DrawCircle(551, 227, 15.0, rl.BLUE)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_RIGHT):
        rl.DrawCircle(587, 191, 15.0, rl.GREEN)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_UP):
        rl.DrawCircle(551, 155, 15.0, rl.RED)

    rl.DrawRectangle(245, 145, 28, 88, rl.RAYWHITE)
    rl.DrawRectangle(215, 174, 88, 29, rl.RAYWHITE)
    rl.DrawRectangle(247, 147, 24, 84, rl.BLACK)
    rl.DrawRectangle(217, 176, 84, 25, rl.BLACK)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_UP):
        rl.DrawRectangle(247, 147, 24, 29, rl.RED)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN):
        rl.DrawRectangle(247, 201, 24, 30, rl.RED)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_LEFT):
        rl.DrawRectangle(217, 176, 30, 25, rl.RED)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_RIGHT):
        rl.DrawRectangle(271, 176, 30, 25, rl.RED)

    let left_shoulder = rl.Rectangle(x = 215.0, y = 98.0, width = 100.0, height = 10.0)
    let right_shoulder = rl.Rectangle(x = 495.0, y = 98.0, width = 100.0, height = 10.0)
    rl.DrawRectangleRounded(left_shoulder, 0.5, 16, rl.DARKGRAY)
    rl.DrawRectangleRounded(right_shoulder, 0.5, 16, rl.DARKGRAY)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_TRIGGER_1):
        rl.DrawRectangleRounded(left_shoulder, 0.5, 16, rl.RED)
    if rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_TRIGGER_1):
        rl.DrawRectangleRounded(right_shoulder, 0.5, 16, rl.RED)

    draw_stick(345, 260, 40.0, 35.0, left_stick_x, left_stick_y, rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_THUMB))
    draw_stick(465, 260, 40.0, 35.0, right_stick_x, right_stick_y, rl.IsGamepadButtonDown(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_THUMB))
    draw_trigger_bar(151, 110, left_trigger)
    draw_trigger_bar(644, 110, right_trigger)
    return


def draw_axis_values(gamepad: i32, axis_count: i32) -> void:
    rl.DrawText(rl.TextFormat(c"DETECTED AXIS [%i]:", axis_count), 10, 50, 10, rl.MAROON)
    for axis_index in range(0, axis_count):
        rl.DrawText(rl.TextFormat(c"AXIS %i: %.02f", axis_index, rl.GetGamepadAxisMovement(gamepad, axis_index)), 20, 70 + 20 * axis_index, 10, rl.DARKGRAY)
    return


def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let tex_ps3_pad = rl.LoadTexture(ps3_texture_path)
    defer rl.UnloadTexture(tex_ps3_pad)
    let tex_xbox_pad = rl.LoadTexture(xbox_texture_path)
    defer rl.UnloadTexture(tex_xbox_pad)

    var vibrate_button = zero[rl.Rectangle]()
    var gamepad = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT) and gamepad > 0:
            gamepad -= 1
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            gamepad += 1

        let mouse_position = rl.GetMousePosition()
        let axis_count = rl.GetGamepadAxisCount(gamepad)

        vibrate_button = rl.Rectangle(
            x = 10.0,
            y = 90.0 + f32<-(20 * axis_count),
            width = 75.0,
            height = 24.0,
        )

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT) and rl.CheckCollisionPointRec(mouse_position, vibrate_button):
            rl.SetGamepadVibration(gamepad, 1.0, 1.0, 1.0)

        rl.BeginDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        if rl.IsGamepadAvailable(gamepad):
            let gamepad_name = rl.GetGamepadName(gamepad)
            rl.DrawText(rl.TextFormat(c"GP%i: %s", gamepad, gamepad_name), 10, 10, 10, rl.BLACK)

            var left_stick_x = rl.GetGamepadAxisMovement(gamepad, rl.GamepadAxis.GAMEPAD_AXIS_LEFT_X)
            var left_stick_y = rl.GetGamepadAxisMovement(gamepad, rl.GamepadAxis.GAMEPAD_AXIS_LEFT_Y)
            var right_stick_x = rl.GetGamepadAxisMovement(gamepad, rl.GamepadAxis.GAMEPAD_AXIS_RIGHT_X)
            var right_stick_y = rl.GetGamepadAxisMovement(gamepad, rl.GamepadAxis.GAMEPAD_AXIS_RIGHT_Y)
            var left_trigger = rl.GetGamepadAxisMovement(gamepad, rl.GamepadAxis.GAMEPAD_AXIS_LEFT_TRIGGER)
            var right_trigger = rl.GetGamepadAxisMovement(gamepad, rl.GamepadAxis.GAMEPAD_AXIS_RIGHT_TRIGGER)

            if left_stick_x > -left_stick_deadzone_x and left_stick_x < left_stick_deadzone_x:
                left_stick_x = 0.0
            if left_stick_y > -left_stick_deadzone_y and left_stick_y < left_stick_deadzone_y:
                left_stick_y = 0.0
            if right_stick_x > -right_stick_deadzone_x and right_stick_x < right_stick_deadzone_x:
                right_stick_x = 0.0
            if right_stick_y > -right_stick_deadzone_y and right_stick_y < right_stick_deadzone_y:
                right_stick_y = 0.0
            if left_trigger < left_trigger_deadzone:
                left_trigger = -1.0
            if right_trigger < right_trigger_deadzone:
                right_trigger = -1.0

            if gamepad_name_matches(gamepad_name, xbox_alias_1, xbox_alias_2):
                draw_xbox_gamepad(gamepad, tex_xbox_pad, left_stick_x, left_stick_y, right_stick_x, right_stick_y, left_trigger, right_trigger)
            elif gamepad_name_matches(gamepad_name, ps_alias_1, ps_alias_2):
                draw_ps_gamepad(gamepad, tex_ps3_pad, left_stick_x, left_stick_y, right_stick_x, right_stick_y, left_trigger, right_trigger)
            else:
                draw_generic_gamepad(gamepad, left_stick_x, left_stick_y, right_stick_x, right_stick_y, left_trigger, right_trigger)

            draw_axis_values(gamepad, axis_count)

            rl.DrawRectangleRec(vibrate_button, rl.SKYBLUE)
            rl.DrawText(c"VIBRATE", i32<-(vibrate_button.x + 14.0), i32<-(vibrate_button.y + 1.0), 10, rl.DARKGRAY)

            let detected_button = rl.GetGamepadButtonPressed()
            if detected_button != i32<-rl.GamepadButton.GAMEPAD_BUTTON_UNKNOWN:
                rl.DrawText(rl.TextFormat(c"DETECTED BUTTON: %i", detected_button), 10, 430, 10, rl.RED)
            else:
                rl.DrawText(c"DETECTED BUTTON: NONE", 10, 430, 10, rl.GRAY)
        else:
            rl.DrawText(rl.TextFormat(c"GP%i: NOT DETECTED", gamepad), 10, 10, 10, rl.GRAY)
            rl.DrawTexture(tex_xbox_pad, 0, 0, rl.LIGHTGRAY)

        rl.EndDrawing()

    return 0
