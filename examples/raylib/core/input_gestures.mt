import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_GESTURE_STRINGS: int = 20


function gesture_label(gesture: int) -> str:
    if gesture == int<-rl.Gesture.GESTURE_TAP:
        return "GESTURE TAP"
    if gesture == int<-rl.Gesture.GESTURE_DOUBLETAP:
        return "GESTURE DOUBLETAP"
    if gesture == int<-rl.Gesture.GESTURE_HOLD:
        return "GESTURE HOLD"
    if gesture == int<-rl.Gesture.GESTURE_DRAG:
        return "GESTURE DRAG"
    if gesture == int<-rl.Gesture.GESTURE_SWIPE_RIGHT:
        return "GESTURE SWIPE RIGHT"
    if gesture == int<-rl.Gesture.GESTURE_SWIPE_LEFT:
        return "GESTURE SWIPE LEFT"
    if gesture == int<-rl.Gesture.GESTURE_SWIPE_UP:
        return "GESTURE SWIPE UP"
    if gesture == int<-rl.Gesture.GESTURE_SWIPE_DOWN:
        return "GESTURE SWIPE DOWN"
    if gesture == int<-rl.Gesture.GESTURE_PINCH_IN:
        return "GESTURE PINCH IN"
    if gesture == int<-rl.Gesture.GESTURE_PINCH_OUT:
        return "GESTURE PINCH OUT"

    return "GESTURE NONE"


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - input gestures")
    defer rl.close_window()

    var touch_position = rl.Vector2(x = 0.0, y = 0.0)
    let touch_area = rl.Rectangle(
        x = 220.0,
        y = 10.0,
        width = (float<-SCREEN_WIDTH) - 230.0,
        height = (float<-SCREEN_HEIGHT) - 20.0
    )

    var gestures_count = 0
    var gesture_codes: array[int, MAX_GESTURE_STRINGS] = zero[array[int, MAX_GESTURE_STRINGS]]
    var current_gesture = int<-rl.Gesture.GESTURE_NONE
    var last_gesture = int<-rl.Gesture.GESTURE_NONE

    rl.set_target_fps(60)

    while not rl.window_should_close():
        last_gesture = current_gesture
        current_gesture = rl.get_gesture_detected()
        touch_position = rl.get_touch_position(0)

        if rl.check_collision_point_rec(touch_position, touch_area) and current_gesture != int<-rl.Gesture.GESTURE_NONE:
            if current_gesture != last_gesture:
                gesture_codes[gestures_count] = current_gesture
                gestures_count += 1

                if gestures_count >= MAX_GESTURE_STRINGS:
                    gestures_count = 0

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_rectangle_rec(touch_area, rl.GRAY)
        rl.draw_rectangle(225, 15, SCREEN_WIDTH - 240, SCREEN_HEIGHT - 30, rl.RAYWHITE)
        rl.draw_text("GESTURES TEST AREA", SCREEN_WIDTH - 270, SCREEN_HEIGHT - 40, 20, rl.fade(rl.GRAY, 0.5))

        var index = 0
        while index < gestures_count:
            if (index % 2) == 0:
                rl.draw_rectangle(10, 30 + 20 * index, 200, 20, rl.fade(rl.LIGHTGRAY, 0.5))
            else:
                rl.draw_rectangle(10, 30 + 20 * index, 200, 20, rl.fade(rl.LIGHTGRAY, 0.3))

            let color = if index < gestures_count - 1: rl.DARKGRAY else: rl.MAROON
            rl.draw_text(gesture_label(gesture_codes[index]), 35, 36 + 20 * index, 10, color)
            index += 1

        rl.draw_rectangle_lines(10, 29, 200, SCREEN_HEIGHT - 50, rl.GRAY)
        rl.draw_text("DETECTED GESTURES", 50, 15, 10, rl.GRAY)

        if current_gesture != int<-rl.Gesture.GESTURE_NONE:
            rl.draw_circle_v(touch_position, 30.0, rl.MAROON)

        rl.end_drawing()

    return 0
