module examples.raylib.core.core_input_gestures_testbed

import std.c.libm as math
import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const gesture_log_size: i32 = 20
const max_touch_count: i32 = 32
const window_title: cstr = c"raylib [core] example - input gestures testbed"
const mobile_message: cstr = c"Example optimized for Web/HTML5\non Smartphones with Touch Screen."
const desktop_message: cstr = c"While running on Desktop Web Browsers,\ninspect and turn on Touch Emulation."


def gesture_name(gesture: i32) -> cstr:
    if gesture == rl.Gesture.GESTURE_TAP:
        return c"Tap"
    if gesture == rl.Gesture.GESTURE_DOUBLETAP:
        return c"Double Tap"
    if gesture == rl.Gesture.GESTURE_HOLD:
        return c"Hold"
    if gesture == rl.Gesture.GESTURE_DRAG:
        return c"Drag"
    if gesture == rl.Gesture.GESTURE_SWIPE_RIGHT:
        return c"Swipe Right"
    if gesture == rl.Gesture.GESTURE_SWIPE_LEFT:
        return c"Swipe Left"
    if gesture == rl.Gesture.GESTURE_SWIPE_UP:
        return c"Swipe Up"
    if gesture == rl.Gesture.GESTURE_SWIPE_DOWN:
        return c"Swipe Down"
    if gesture == rl.Gesture.GESTURE_PINCH_IN:
        return c"Pinch In"
    if gesture == rl.Gesture.GESTURE_PINCH_OUT:
        return c"Pinch Out"
    return c"None"


def gesture_color_for(gesture: i32) -> rl.Color:
    if gesture == rl.Gesture.GESTURE_TAP:
        return rl.BLUE
    if gesture == rl.Gesture.GESTURE_DOUBLETAP:
        return rl.SKYBLUE
    if gesture == rl.Gesture.GESTURE_DRAG:
        return rl.LIME
    if gesture == rl.Gesture.GESTURE_SWIPE_RIGHT:
        return rl.RED
    if gesture == rl.Gesture.GESTURE_SWIPE_LEFT:
        return rl.RED
    if gesture == rl.Gesture.GESTURE_SWIPE_UP:
        return rl.RED
    if gesture == rl.Gesture.GESTURE_SWIPE_DOWN:
        return rl.RED
    if gesture == rl.Gesture.GESTURE_PINCH_IN:
        return rl.VIOLET
    if gesture == rl.Gesture.GESTURE_PINCH_OUT:
        return rl.ORANGE
    return rl.BLACK


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let message_position = rl.Vector2(x = 160.0, y = 7.0)
    var last_gesture: i32 = rl.Gesture.GESTURE_NONE
    let last_gesture_position = rl.Vector2(x = 165.0, y = 130.0)

    var gesture_log = zero[array[cstr, 20]]()
    for index in 0..gesture_log_size:
        gesture_log[index] = c""
    var gesture_log_index = gesture_log_size
    var previous_gesture: i32 = rl.Gesture.GESTURE_NONE
    var log_mode = 1

    var current_gesture_color = rl.Color(r = 0, g = 0, b = 0, a = 255)
    let log_button1 = rl.Rectangle(x = 53.0, y = 7.0, width = 48.0, height = 26.0)
    let log_button2 = rl.Rectangle(x = 108.0, y = 7.0, width = 36.0, height = 26.0)
    let gesture_log_position = rl.Vector2(x = 10.0, y = 10.0)

    let angle_length: f32 = 90.0
    var current_angle_degrees: f32 = 0.0
    var final_vector = rl.Vector2(x = 0.0, y = 0.0)
    let protractor_position = rl.Vector2(x = 266.0, y = 315.0)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let current_gesture = rl.GetGestureDetected()
        let current_drag_degrees = rl.GetGestureDragAngle()
        let current_pitch_degrees = rl.GetGesturePinchAngle()
        let touch_count = rl.GetTouchPointCount()

        if current_gesture != rl.Gesture.GESTURE_NONE and current_gesture != rl.Gesture.GESTURE_HOLD and current_gesture != previous_gesture:
            last_gesture = current_gesture

        if rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT):
            if rl.CheckCollisionPointRec(rl.GetMousePosition(), log_button1):
                if log_mode == 3:
                    log_mode = 2
                elif log_mode == 2:
                    log_mode = 3
                elif log_mode == 1:
                    log_mode = 0
                else:
                    log_mode = 1
            elif rl.CheckCollisionPointRec(rl.GetMousePosition(), log_button2):
                if log_mode == 3:
                    log_mode = 1
                elif log_mode == 2:
                    log_mode = 0
                elif log_mode == 1:
                    log_mode = 3
                else:
                    log_mode = 2

        var fill_log = false
        if current_gesture != rl.Gesture.GESTURE_NONE:
            if log_mode == 3:
                if ((current_gesture != rl.Gesture.GESTURE_HOLD and current_gesture != previous_gesture) or current_gesture < 3):
                    fill_log = true
            elif log_mode == 2:
                if current_gesture != rl.Gesture.GESTURE_HOLD:
                    fill_log = true
            elif log_mode == 1:
                if current_gesture != previous_gesture:
                    fill_log = true
            else:
                fill_log = true

        if fill_log:
            previous_gesture = current_gesture
            current_gesture_color = gesture_color_for(current_gesture)
            if gesture_log_index <= 0:
                gesture_log_index = gesture_log_size
            gesture_log_index -= 1
            gesture_log[gesture_log_index] = gesture_name(current_gesture)

        if current_gesture == rl.Gesture.GESTURE_PINCH_IN or current_gesture == rl.Gesture.GESTURE_PINCH_OUT:
            current_angle_degrees = current_pitch_degrees
        elif current_gesture == rl.Gesture.GESTURE_SWIPE_RIGHT or current_gesture == rl.Gesture.GESTURE_SWIPE_LEFT or current_gesture == rl.Gesture.GESTURE_SWIPE_UP or current_gesture == rl.Gesture.GESTURE_SWIPE_DOWN:
            current_angle_degrees = current_drag_degrees
        elif current_gesture != rl.Gesture.GESTURE_NONE:
            current_angle_degrees = 0.0

        let current_angle_radians = (current_angle_degrees + 90.0) * rl.PI / 180.0
        final_vector = rl.Vector2(
            x = angle_length * math.sinf(current_angle_radians) + protractor_position.x,
            y = angle_length * math.cosf(current_angle_radians) + protractor_position.y,
        )

        var touch_positions = zero[array[rl.Vector2, 32]]()
        var mouse_position = rl.Vector2(x = 0.0, y = 0.0)
        if current_gesture != rl.Gesture.GESTURE_NONE:
            if touch_count != 0:
                var touch_index = 0
                while touch_index < touch_count and touch_index < max_touch_count:
                    touch_positions[touch_index] = rl.GetTouchPosition(touch_index)
                    touch_index += 1
            else:
                mouse_position = rl.GetMousePosition()

        rl.BeginDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawText(c"*", i32<-message_position.x + 5, i32<-message_position.y + 5, 10, rl.BLACK)
        rl.DrawText(mobile_message, i32<-message_position.x + 15, i32<-message_position.y + 5, 10, rl.BLACK)
        rl.DrawText(c"*", i32<-message_position.x + 5, i32<-message_position.y + 35, 10, rl.BLACK)
        rl.DrawText(desktop_message, i32<-message_position.x + 15, i32<-message_position.y + 35, 10, rl.BLACK)

        var swipe_up_color = rl.LIGHTGRAY
        var swipe_left_color = rl.LIGHTGRAY
        var swipe_right_color = rl.LIGHTGRAY
        var swipe_down_color = rl.LIGHTGRAY
        var tap_color = rl.LIGHTGRAY
        var drag_color = rl.LIGHTGRAY
        var doubletap_color = rl.LIGHTGRAY
        var pinch_out_color = rl.LIGHTGRAY
        var pinch_in_color = rl.LIGHTGRAY
        if last_gesture == rl.Gesture.GESTURE_SWIPE_UP:
            swipe_up_color = rl.RED
        if last_gesture == rl.Gesture.GESTURE_SWIPE_LEFT:
            swipe_left_color = rl.RED
        if last_gesture == rl.Gesture.GESTURE_SWIPE_RIGHT:
            swipe_right_color = rl.RED
        if last_gesture == rl.Gesture.GESTURE_SWIPE_DOWN:
            swipe_down_color = rl.RED
        if last_gesture == rl.Gesture.GESTURE_TAP:
            tap_color = rl.BLUE
        if last_gesture == rl.Gesture.GESTURE_DRAG:
            drag_color = rl.LIME
        if last_gesture == rl.Gesture.GESTURE_DOUBLETAP:
            doubletap_color = rl.SKYBLUE
        if last_gesture == rl.Gesture.GESTURE_PINCH_OUT:
            pinch_out_color = rl.ORANGE
        if last_gesture == rl.Gesture.GESTURE_PINCH_IN:
            pinch_in_color = rl.VIOLET

        rl.DrawText(c"Last gesture", i32<-last_gesture_position.x + 33, i32<-last_gesture_position.y - 47, 20, rl.BLACK)
        rl.DrawText(c"Swipe         Tap       Pinch  Touch", i32<-last_gesture_position.x + 17, i32<-last_gesture_position.y - 18, 10, rl.BLACK)
        rl.DrawRectangle(i32<-last_gesture_position.x + 20, i32<-last_gesture_position.y, 20, 20, swipe_up_color)
        rl.DrawRectangle(i32<-last_gesture_position.x, i32<-last_gesture_position.y + 20, 20, 20, swipe_left_color)
        rl.DrawRectangle(i32<-last_gesture_position.x + 40, i32<-last_gesture_position.y + 20, 20, 20, swipe_right_color)
        rl.DrawRectangle(i32<-last_gesture_position.x + 20, i32<-last_gesture_position.y + 40, 20, 20, swipe_down_color)
        rl.DrawCircle(i32<-last_gesture_position.x + 80, i32<-last_gesture_position.y + 16, 10.0, tap_color)
        rl.DrawRing(rl.Vector2(x = last_gesture_position.x + 103.0, y = last_gesture_position.y + 16.0), 6.0, 11.0, 0.0, 360.0, 0, drag_color)
        rl.DrawCircle(i32<-last_gesture_position.x + 80, i32<-last_gesture_position.y + 43, 10.0, doubletap_color)
        rl.DrawCircle(i32<-last_gesture_position.x + 103, i32<-last_gesture_position.y + 43, 10.0, doubletap_color)
        rl.DrawTriangle(rl.Vector2(x = last_gesture_position.x + 122.0, y = last_gesture_position.y + 16.0), rl.Vector2(x = last_gesture_position.x + 137.0, y = last_gesture_position.y + 26.0), rl.Vector2(x = last_gesture_position.x + 137.0, y = last_gesture_position.y + 6.0), pinch_out_color)
        rl.DrawTriangle(rl.Vector2(x = last_gesture_position.x + 147.0, y = last_gesture_position.y + 6.0), rl.Vector2(x = last_gesture_position.x + 147.0, y = last_gesture_position.y + 26.0), rl.Vector2(x = last_gesture_position.x + 162.0, y = last_gesture_position.y + 16.0), pinch_out_color)
        rl.DrawTriangle(rl.Vector2(x = last_gesture_position.x + 125.0, y = last_gesture_position.y + 33.0), rl.Vector2(x = last_gesture_position.x + 125.0, y = last_gesture_position.y + 53.0), rl.Vector2(x = last_gesture_position.x + 140.0, y = last_gesture_position.y + 43.0), pinch_in_color)
        rl.DrawTriangle(rl.Vector2(x = last_gesture_position.x + 144.0, y = last_gesture_position.y + 43.0), rl.Vector2(x = last_gesture_position.x + 159.0, y = last_gesture_position.y + 53.0), rl.Vector2(x = last_gesture_position.x + 159.0, y = last_gesture_position.y + 33.0), pinch_in_color)

        for touch_indicator in 0..4:
            rl.DrawCircle(i32<-last_gesture_position.x + 180, i32<-last_gesture_position.y + 7 + touch_indicator * 15, 5.0, if touch_count <= touch_indicator: rl.LIGHTGRAY else: current_gesture_color)

        rl.DrawText(c"Log", i32<-gesture_log_position.x, i32<-gesture_log_position.y, 20, rl.BLACK)
        var log_row = 0
        var log_index = gesture_log_index % gesture_log_size
        while log_row < gesture_log_size:
            rl.DrawText(gesture_log[log_index], i32<-gesture_log_position.x, i32<-gesture_log_position.y + 410 - log_row * 20, 20, if log_row == 0: current_gesture_color else: rl.LIGHTGRAY)
            log_row += 1
            log_index = (log_index + 1) % gesture_log_size

        var log_button1_color = rl.GRAY
        var log_button2_color = rl.GRAY
        if log_mode == 3:
            log_button1_color = rl.MAROON
            log_button2_color = rl.MAROON
        elif log_mode == 2:
            log_button2_color = rl.MAROON
        elif log_mode == 1:
            log_button1_color = rl.MAROON

        rl.DrawRectangleRec(log_button1, log_button1_color)
        rl.DrawText(c"Hide", i32<-log_button1.x + 7, i32<-log_button1.y + 3, 10, rl.WHITE)
        rl.DrawText(c"Repeat", i32<-log_button1.x + 7, i32<-log_button1.y + 13, 10, rl.WHITE)
        rl.DrawRectangleRec(log_button2, log_button2_color)
        rl.DrawText(c"Hide", i32<-log_button1.x + 62, i32<-log_button1.y + 3, 10, rl.WHITE)
        rl.DrawText(c"Hold", i32<-log_button1.x + 62, i32<-log_button1.y + 13, 10, rl.WHITE)

        rl.DrawText(c"Angle", i32<-protractor_position.x + 55, i32<-protractor_position.y + 76, 10, rl.BLACK)
        let angle_string = rl.TextFormat(c"%f", current_angle_degrees)
        let angle_string_dot = rl.TextFindIndex(angle_string, c".")
        let angle_string_trim = rl.TextSubtext(angle_string, 0, angle_string_dot + 3)
        rl.DrawText(angle_string_trim, i32<-protractor_position.x + 55, i32<-protractor_position.y + 92, 20, current_gesture_color)
        rl.DrawCircleV(protractor_position, 80.0, rl.WHITE)
        rl.DrawLineEx(rl.Vector2(x = protractor_position.x - 90.0, y = protractor_position.y), rl.Vector2(x = protractor_position.x + 90.0, y = protractor_position.y), 3.0, rl.LIGHTGRAY)
        rl.DrawLineEx(rl.Vector2(x = protractor_position.x, y = protractor_position.y - 90.0), rl.Vector2(x = protractor_position.x, y = protractor_position.y + 90.0), 3.0, rl.LIGHTGRAY)
        rl.DrawLineEx(rl.Vector2(x = protractor_position.x - 80.0, y = protractor_position.y - 45.0), rl.Vector2(x = protractor_position.x + 80.0, y = protractor_position.y + 45.0), 3.0, rl.GREEN)
        rl.DrawLineEx(rl.Vector2(x = protractor_position.x - 80.0, y = protractor_position.y + 45.0), rl.Vector2(x = protractor_position.x + 80.0, y = protractor_position.y - 45.0), 3.0, rl.GREEN)
        rl.DrawText(c"0", i32<-protractor_position.x + 96, i32<-protractor_position.y - 9, 20, rl.BLACK)
        rl.DrawText(c"30", i32<-protractor_position.x + 74, i32<-protractor_position.y - 68, 20, rl.BLACK)
        rl.DrawText(c"90", i32<-protractor_position.x - 11, i32<-protractor_position.y - 110, 20, rl.BLACK)
        rl.DrawText(c"150", i32<-protractor_position.x - 100, i32<-protractor_position.y - 68, 20, rl.BLACK)
        rl.DrawText(c"180", i32<-protractor_position.x - 124, i32<-protractor_position.y - 9, 20, rl.BLACK)
        rl.DrawText(c"210", i32<-protractor_position.x - 100, i32<-protractor_position.y + 50, 20, rl.BLACK)
        rl.DrawText(c"270", i32<-protractor_position.x - 18, i32<-protractor_position.y + 92, 20, rl.BLACK)
        rl.DrawText(c"330", i32<-protractor_position.x + 72, i32<-protractor_position.y + 50, 20, rl.BLACK)
        if current_angle_degrees != 0.0:
            rl.DrawLineEx(protractor_position, final_vector, 3.0, current_gesture_color)

        if current_gesture != rl.Gesture.GESTURE_NONE:
            if touch_count != 0:
                var touch_index = 0
                while touch_index < touch_count and touch_index < max_touch_count:
                    rl.DrawCircleV(touch_positions[touch_index], 50.0, rl.Fade(current_gesture_color, 0.5))
                    rl.DrawCircleV(touch_positions[touch_index], 5.0, current_gesture_color)
                    touch_index += 1

                if touch_count == 2:
                    rl.DrawLineEx(touch_positions[0], touch_positions[1], if current_gesture == rl.Gesture.GESTURE_PINCH_OUT: 8.0 else: 12.0, current_gesture_color)
            else:
                rl.DrawCircleV(mouse_position, 35.0, rl.Fade(current_gesture_color, 0.5))
                rl.DrawCircleV(mouse_position, 5.0, current_gesture_color)

        rl.EndDrawing()

    return 0
