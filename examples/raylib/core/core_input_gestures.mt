module examples.raylib.core.core_input_gestures

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - input gestures"
const test_area_text: cstr = c"GESTURES TEST AREA"
const detected_text: cstr = c"DETECTED GESTURE"
const gesture_none_text: cstr = c"GESTURE NONE"
const gesture_tap_text: cstr = c"GESTURE TAP"
const gesture_doubletap_text: cstr = c"GESTURE DOUBLETAP"
const gesture_hold_text: cstr = c"GESTURE HOLD"
const gesture_drag_text: cstr = c"GESTURE DRAG"
const gesture_swipe_right_text: cstr = c"GESTURE SWIPE RIGHT"
const gesture_swipe_left_text: cstr = c"GESTURE SWIPE LEFT"
const gesture_swipe_up_text: cstr = c"GESTURE SWIPE UP"
const gesture_swipe_down_text: cstr = c"GESTURE SWIPE DOWN"
const gesture_pinch_in_text: cstr = c"GESTURE PINCH IN"
const gesture_pinch_out_text: cstr = c"GESTURE PINCH OUT"

def gesture_label(gesture: i32) -> cstr:
    if gesture == rl.Gesture.GESTURE_TAP:
        return gesture_tap_text
    if gesture == rl.Gesture.GESTURE_DOUBLETAP:
        return gesture_doubletap_text
    if gesture == rl.Gesture.GESTURE_HOLD:
        return gesture_hold_text
    if gesture == rl.Gesture.GESTURE_DRAG:
        return gesture_drag_text
    if gesture == rl.Gesture.GESTURE_SWIPE_RIGHT:
        return gesture_swipe_right_text
    if gesture == rl.Gesture.GESTURE_SWIPE_LEFT:
        return gesture_swipe_left_text
    if gesture == rl.Gesture.GESTURE_SWIPE_UP:
        return gesture_swipe_up_text
    if gesture == rl.Gesture.GESTURE_SWIPE_DOWN:
        return gesture_swipe_down_text
    if gesture == rl.Gesture.GESTURE_PINCH_IN:
        return gesture_pinch_in_text
    if gesture == rl.Gesture.GESTURE_PINCH_OUT:
        return gesture_pinch_out_text

    return gesture_none_text

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let touch_area = rl.Rectangle(
        x = 220.0,
        y = 10.0,
        width = screen_width - 230.0,
        height = screen_height - 20.0,
    )
    let test_area_fill = rl.Rectangle(
        x = 225.0,
        y = 15.0,
        width = screen_width - 240.0,
        height = screen_height - 30.0,
    )
    let gesture_circle_radius: f32 = 30.0
    let label_alpha: f32 = 0.5

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let current_gesture = rl.GetGestureDetected()
        let touch_position = rl.GetTouchPosition(0)
        let gesture_active = rl.CheckCollisionPointRec(touch_position, touch_area) and current_gesture != rl.Gesture.GESTURE_NONE

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawRectangleRec(touch_area, rl.GRAY)
        rl.DrawRectangleRec(test_area_fill, rl.RAYWHITE)
        rl.DrawText(test_area_text, screen_width - 270, screen_height - 40, 20, rl.Fade(rl.GRAY, label_alpha))
        rl.DrawRectangleLines(10, 29, 200, screen_height - 50, rl.GRAY)
        rl.DrawText(detected_text, 50, 15, 10, rl.GRAY)
        rl.DrawText(gesture_label(current_gesture), 35, 36, 20, rl.MAROON)

        if gesture_active:
            rl.DrawCircleV(touch_position, gesture_circle_radius, rl.MAROON)

    return 0