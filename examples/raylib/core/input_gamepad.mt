import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const LEFT_STICK_DEADZONE_X: float = 0.1
const LEFT_STICK_DEADZONE_Y: float = 0.1
const RIGHT_STICK_DEADZONE_X: float = 0.1
const RIGHT_STICK_DEADZONE_Y: float = 0.1
const LEFT_TRIGGER_DEADZONE: float = -0.9
const RIGHT_TRIGGER_DEADZONE: float = -0.9


function axis_movement(gamepad: int, axis: rl.GamepadAxis) -> float:
    return rl.get_gamepad_axis_movement(gamepad, int<-axis)


function contains_any_name(text_value: str, first: str, second: str, third: str) -> bool:
    return rl.text_find_index(text_value, first) > -1 or rl.text_find_index(
        text_value,
        second
    ) > -1 or rl.text_find_index(text_value, third) > -1


function is_xbox_name(text_value: str) -> bool:
    return contains_any_name(text_value, "xbox", "Xbox", "XBOX") or contains_any_name(
        text_value,
        "x-box",
        "X-Box",
        "X-BOX"
    )


function is_playstation_name(text_value: str) -> bool:
    return contains_any_name(
        text_value,
        "playstation",
        "PlayStation",
        "PLAYSTATION"
    ) or contains_any_name(text_value, "sony", "Sony", "SONY")


function deadzone_axis(value: float, deadzone: float) -> float:
    if value > -deadzone and value < deadzone:
        return 0.0

    return value


function trigger_value(value: float, deadzone: float) -> float:
    if value < deadzone:
        return -1.0

    return value


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - input gamepad")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let tex_ps3_pad = rl.load_texture("ps3.png")
    defer rl.unload_texture(tex_ps3_pad)
    let tex_xbox_pad = rl.load_texture("xbox.png")
    defer rl.unload_texture(tex_xbox_pad)

    var gamepad = 0
    var vibrate_button = rl.Rectangle(x = 0.0, y = 0.0, width = 0.0, height = 0.0)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT) and gamepad > 0:
            gamepad -= 1
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            gamepad += 1

        let mouse_position = rl.get_mouse_position()
        vibrate_button = rl.Rectangle(
            x = 10.0,
            y = 70.0 + float<-(20 * rl.get_gamepad_axis_count(gamepad) + 20),
            width = 75.0,
            height = 24.0
        )
        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT) and rl.check_collision_point_rec(
            mouse_position,
            vibrate_button
        ):
            rl.set_gamepad_vibration(gamepad, 1.0, 1.0, 1.0)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        if rl.is_gamepad_available(gamepad):
            let gamepad_name = text.cstr_as_str(rl.get_gamepad_name(gamepad))
            rl.draw_text(f"GP#{gamepad}: #{gamepad_name}", 10, 10, 10, rl.BLACK)

            let left_stick_x = deadzone_axis(
                axis_movement(gamepad, rl.GamepadAxis.GAMEPAD_AXIS_LEFT_X),
                LEFT_STICK_DEADZONE_X
            )
            let left_stick_y = deadzone_axis(
                axis_movement(gamepad, rl.GamepadAxis.GAMEPAD_AXIS_LEFT_Y),
                LEFT_STICK_DEADZONE_Y
            )
            let right_stick_x = deadzone_axis(
                axis_movement(gamepad, rl.GamepadAxis.GAMEPAD_AXIS_RIGHT_X),
                RIGHT_STICK_DEADZONE_X
            )
            let right_stick_y = deadzone_axis(
                axis_movement(gamepad, rl.GamepadAxis.GAMEPAD_AXIS_RIGHT_Y),
                RIGHT_STICK_DEADZONE_Y
            )
            let left_trigger = trigger_value(
                axis_movement(gamepad, rl.GamepadAxis.GAMEPAD_AXIS_LEFT_TRIGGER),
                LEFT_TRIGGER_DEADZONE
            )
            let right_trigger = trigger_value(
                axis_movement(gamepad, rl.GamepadAxis.GAMEPAD_AXIS_RIGHT_TRIGGER),
                RIGHT_TRIGGER_DEADZONE
            )

            if is_xbox_name(gamepad_name):
                rl.draw_texture(tex_xbox_pad, 0, 0, rl.DARKGRAY)

                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_MIDDLE):
                    rl.draw_circle(394, 89, 19.0, rl.RED)

                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_MIDDLE_RIGHT):
                    rl.draw_circle(436, 150, 9.0, rl.RED)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_MIDDLE_LEFT):
                    rl.draw_circle(352, 150, 9.0, rl.RED)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_LEFT):
                    rl.draw_circle(501, 151, 15.0, rl.BLUE)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN):
                    rl.draw_circle(536, 187, 15.0, rl.LIME)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_RIGHT):
                    rl.draw_circle(572, 151, 15.0, rl.MAROON)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_UP):
                    rl.draw_circle(536, 115, 15.0, rl.GOLD)

                rl.draw_rectangle(317, 202, 19, 71, rl.BLACK)
                rl.draw_rectangle(293, 228, 69, 19, rl.BLACK)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_UP):
                    rl.draw_rectangle(317, 202, 19, 26, rl.RED)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN):
                    rl.draw_rectangle(317, 247, 19, 26, rl.RED)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_LEFT):
                    rl.draw_rectangle(292, 228, 25, 19, rl.RED)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_RIGHT):
                    rl.draw_rectangle(336, 228, 26, 19, rl.RED)

                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_TRIGGER_1):
                    rl.draw_circle(259, 61, 20.0, rl.RED)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_TRIGGER_1):
                    rl.draw_circle(536, 61, 20.0, rl.RED)

                var left_gamepad_color = rl.BLACK
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_THUMB):
                    left_gamepad_color = rl.RED
                rl.draw_circle(259, 152, 39.0, rl.BLACK)
                rl.draw_circle(259, 152, 34.0, rl.LIGHTGRAY)
                rl.draw_circle(
                    259 + int<-(left_stick_x * 20.0),
                    152 + int<-(left_stick_y * 20.0),
                    25.0,
                    left_gamepad_color
                )

                var right_gamepad_color = rl.BLACK
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_THUMB):
                    right_gamepad_color = rl.RED
                rl.draw_circle(461, 237, 38.0, rl.BLACK)
                rl.draw_circle(461, 237, 33.0, rl.LIGHTGRAY)
                rl.draw_circle(
                    461 + int<-(right_stick_x * 20.0),
                    237 + int<-(right_stick_y * 20.0),
                    25.0,
                    right_gamepad_color
                )

                rl.draw_rectangle(170, 30, 15, 70, rl.GRAY)
                rl.draw_rectangle(604, 30, 15, 70, rl.GRAY)
                rl.draw_rectangle(170, 30, 15, int<-(((1.0 + left_trigger) / 2.0) * 70.0), rl.RED)
                rl.draw_rectangle(604, 30, 15, int<-(((1.0 + right_trigger) / 2.0) * 70.0), rl.RED)
            else if is_playstation_name(gamepad_name):
                rl.draw_texture(tex_ps3_pad, 0, 0, rl.DARKGRAY)

                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_MIDDLE):
                    rl.draw_circle(396, 222, 13.0, rl.RED)

                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_MIDDLE_LEFT):
                    rl.draw_rectangle(328, 170, 32, 13, rl.RED)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_MIDDLE_RIGHT):
                    rl.draw_triangle(
                        rl.Vector2(x = 436.0, y = 168.0),
                        rl.Vector2(x = 436.0, y = 185.0),
                        rl.Vector2(x = 464.0, y = 177.0),
                        rl.RED
                    )
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_UP):
                    rl.draw_circle(557, 144, 13.0, rl.LIME)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_RIGHT):
                    rl.draw_circle(586, 173, 13.0, rl.RED)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN):
                    rl.draw_circle(557, 203, 13.0, rl.VIOLET)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_LEFT):
                    rl.draw_circle(527, 173, 13.0, rl.PINK)

                rl.draw_rectangle(225, 132, 24, 84, rl.BLACK)
                rl.draw_rectangle(195, 161, 84, 25, rl.BLACK)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_UP):
                    rl.draw_rectangle(225, 132, 24, 29, rl.RED)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN):
                    rl.draw_rectangle(225, 186, 24, 30, rl.RED)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_LEFT):
                    rl.draw_rectangle(195, 161, 30, 25, rl.RED)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_RIGHT):
                    rl.draw_rectangle(249, 161, 30, 25, rl.RED)

                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_TRIGGER_1):
                    rl.draw_circle(239, 82, 20.0, rl.RED)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_TRIGGER_1):
                    rl.draw_circle(557, 82, 20.0, rl.RED)

                var left_gamepad_color = rl.BLACK
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_THUMB):
                    left_gamepad_color = rl.RED
                rl.draw_circle(319, 255, 35.0, rl.BLACK)
                rl.draw_circle(319, 255, 31.0, rl.LIGHTGRAY)
                rl.draw_circle(
                    319 + int<-(left_stick_x * 20.0),
                    255 + int<-(left_stick_y * 20.0),
                    25.0,
                    left_gamepad_color
                )

                var right_gamepad_color = rl.BLACK
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_THUMB):
                    right_gamepad_color = rl.RED
                rl.draw_circle(475, 255, 35.0, rl.BLACK)
                rl.draw_circle(475, 255, 31.0, rl.LIGHTGRAY)
                rl.draw_circle(
                    475 + int<-(right_stick_x * 20.0),
                    255 + int<-(right_stick_y * 20.0),
                    25.0,
                    right_gamepad_color
                )

                rl.draw_rectangle(169, 48, 15, 70, rl.GRAY)
                rl.draw_rectangle(611, 48, 15, 70, rl.GRAY)
                rl.draw_rectangle(169, 48, 15, int<-(((1.0 + left_trigger) / 2.0) * 70.0), rl.RED)
                rl.draw_rectangle(611, 48, 15, int<-(((1.0 + right_trigger) / 2.0) * 70.0), rl.RED)
            else:
                rl.draw_rectangle_rounded(
                    rl.Rectangle(x = 175.0, y = 110.0, width = 460.0, height = 220.0),
                    0.3,
                    16,
                    rl.DARKGRAY
                )

                rl.draw_circle(365, 170, 12.0, rl.RAYWHITE)
                rl.draw_circle(405, 170, 12.0, rl.RAYWHITE)
                rl.draw_circle(445, 170, 12.0, rl.RAYWHITE)
                rl.draw_circle(516, 191, 17.0, rl.RAYWHITE)
                rl.draw_circle(551, 227, 17.0, rl.RAYWHITE)
                rl.draw_circle(587, 191, 17.0, rl.RAYWHITE)
                rl.draw_circle(551, 155, 17.0, rl.RAYWHITE)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_MIDDLE_LEFT):
                    rl.draw_circle(365, 170, 10.0, rl.RED)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_MIDDLE):
                    rl.draw_circle(405, 170, 10.0, rl.GREEN)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_MIDDLE_RIGHT):
                    rl.draw_circle(445, 170, 10.0, rl.BLUE)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_LEFT):
                    rl.draw_circle(516, 191, 15.0, rl.GOLD)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_DOWN):
                    rl.draw_circle(551, 227, 15.0, rl.BLUE)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_RIGHT):
                    rl.draw_circle(587, 191, 15.0, rl.GREEN)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_FACE_UP):
                    rl.draw_circle(551, 155, 15.0, rl.RED)

                rl.draw_rectangle(245, 145, 28, 88, rl.RAYWHITE)
                rl.draw_rectangle(215, 174, 88, 29, rl.RAYWHITE)
                rl.draw_rectangle(247, 147, 24, 84, rl.BLACK)
                rl.draw_rectangle(217, 176, 84, 25, rl.BLACK)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_UP):
                    rl.draw_rectangle(247, 147, 24, 29, rl.RED)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_DOWN):
                    rl.draw_rectangle(247, 201, 24, 30, rl.RED)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_LEFT):
                    rl.draw_rectangle(217, 176, 30, 25, rl.RED)
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_FACE_RIGHT):
                    rl.draw_rectangle(271, 176, 30, 25, rl.RED)

                rl.draw_rectangle_rounded(
                    rl.Rectangle(x = 215.0, y = 98.0, width = 100.0, height = 10.0),
                    0.5,
                    16,
                    rl.DARKGRAY
                )
                rl.draw_rectangle_rounded(
                    rl.Rectangle(x = 495.0, y = 98.0, width = 100.0, height = 10.0),
                    0.5,
                    16,
                    rl.DARKGRAY
                )
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_TRIGGER_1):
                    rl.draw_rectangle_rounded(
                        rl.Rectangle(x = 215.0, y = 98.0, width = 100.0, height = 10.0),
                        0.5,
                        16,
                        rl.RED
                    )
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_TRIGGER_1):
                    rl.draw_rectangle_rounded(
                        rl.Rectangle(x = 495.0, y = 98.0, width = 100.0, height = 10.0),
                        0.5,
                        16,
                        rl.RED
                    )

                var left_gamepad_color = rl.BLACK
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_LEFT_THUMB):
                    left_gamepad_color = rl.RED
                rl.draw_circle(345, 260, 40.0, rl.BLACK)
                rl.draw_circle(345, 260, 35.0, rl.LIGHTGRAY)
                rl.draw_circle(
                    345 + int<-(left_stick_x * 20.0),
                    260 + int<-(left_stick_y * 20.0),
                    25.0,
                    left_gamepad_color
                )

                var right_gamepad_color = rl.BLACK
                if rl.is_gamepad_button_down(gamepad, rl.GamepadButton.GAMEPAD_BUTTON_RIGHT_THUMB):
                    right_gamepad_color = rl.RED
                rl.draw_circle(465, 260, 40.0, rl.BLACK)
                rl.draw_circle(465, 260, 35.0, rl.LIGHTGRAY)
                rl.draw_circle(
                    465 + int<-(right_stick_x * 20.0),
                    260 + int<-(right_stick_y * 20.0),
                    25.0,
                    right_gamepad_color
                )

                rl.draw_rectangle(151, 110, 15, 70, rl.GRAY)
                rl.draw_rectangle(644, 110, 15, 70, rl.GRAY)
                rl.draw_rectangle(151, 110, 15, int<-(((1.0 + left_trigger) / 2.0) * 70.0), rl.RED)
                rl.draw_rectangle(644, 110, 15, int<-(((1.0 + right_trigger) / 2.0) * 70.0), rl.RED)

            rl.draw_text(f"DETECTED AXIS [#{rl.get_gamepad_axis_count(gamepad)}]:", 10, 50, 10, rl.MAROON)

            var axis_index = 0
            while axis_index < rl.get_gamepad_axis_count(gamepad):
                rl.draw_text(
                    f"AXIS #{axis_index}: #{rl.get_gamepad_axis_movement(gamepad, axis_index)}",
                    20,
                    70 + 20 * axis_index,
                    10,
                    rl.DARKGRAY
                )
                axis_index += 1

            rl.draw_rectangle_rec(vibrate_button, rl.SKYBLUE)
            rl.draw_text("VIBRATE", int<-(vibrate_button.x + 14.0), int<-(vibrate_button.y + 1.0), 10, rl.DARKGRAY)

            let button_pressed = rl.get_gamepad_button_pressed()
            if button_pressed != int<-rl.GamepadButton.GAMEPAD_BUTTON_UNKNOWN:
                rl.draw_text(f"DETECTED BUTTON: #{button_pressed}", 10, 430, 10, rl.RED)
            else:
                rl.draw_text("DETECTED BUTTON: NONE", 10, 430, 10, rl.GRAY)
        else:
            rl.draw_text(f"GP#{gamepad}: NOT DETECTED", 10, 10, 10, rl.GRAY)
            rl.draw_texture(tex_xbox_pad, 0, 0, rl.LIGHTGRAY)

        rl.end_drawing()

    return 0
