module examples.idiomatic.raylib.input_gestures

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450


def gesture_label(gesture: i32) -> str:
    if gesture == rl.Gesture.GESTURE_TAP:
        return "GESTURE TAP"
    if gesture == rl.Gesture.GESTURE_DOUBLETAP:
        return "GESTURE DOUBLETAP"
    if gesture == rl.Gesture.GESTURE_HOLD:
        return "GESTURE HOLD"
    if gesture == rl.Gesture.GESTURE_DRAG:
        return "GESTURE DRAG"
    if gesture == rl.Gesture.GESTURE_SWIPE_RIGHT:
        return "GESTURE SWIPE RIGHT"
    if gesture == rl.Gesture.GESTURE_SWIPE_LEFT:
        return "GESTURE SWIPE LEFT"
    if gesture == rl.Gesture.GESTURE_SWIPE_UP:
        return "GESTURE SWIPE UP"
    if gesture == rl.Gesture.GESTURE_SWIPE_DOWN:
        return "GESTURE SWIPE DOWN"
    if gesture == rl.Gesture.GESTURE_PINCH_IN:
        return "GESTURE PINCH IN"
    if gesture == rl.Gesture.GESTURE_PINCH_OUT:
        return "GESTURE PINCH OUT"
    return "GESTURE NONE"


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Gestures")
    defer rl.close_window()

    let touch_area = rl.Rectangle(
        x = 220,
        y = 10,
        width = screen_width - 230,
        height = screen_height - 20,
    )
    let test_area_fill = rl.Rectangle(
        x = 225,
        y = 15,
        width = screen_width - 240,
        height = screen_height - 30,
    )

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let current_gesture = rl.get_gesture_detected()
        let touch_position = rl.get_touch_position(0)
        let gesture_active = rl.check_collision_point_rec(touch_position, touch_area) and current_gesture != rl.Gesture.GESTURE_NONE

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_rectangle_rec(touch_area, rl.GRAY)
        rl.draw_rectangle_rec(test_area_fill, rl.RAYWHITE)
        rl.draw_text("GESTURES TEST AREA", screen_width - 270, screen_height - 40, 20, rl.fade(rl.GRAY, 0.5))
        rl.draw_rectangle_lines(10, 29, 200, screen_height - 50, rl.GRAY)
        rl.draw_text("DETECTED GESTURE", 50, 15, 10, rl.GRAY)
        rl.draw_text(gesture_label(current_gesture), 35, 36, 20, rl.MAROON)

        if gesture_active:
            rl.draw_circle_v(touch_position, 30.0, rl.MAROON)

    return 0
