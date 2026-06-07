import std.math as math
import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GESTURE_LOG_SIZE: int = 20
const MAX_TOUCH_COUNT: int = 32
const DEGREE_DIVISOR: float = 180.0
const ANGLE_OFFSET: float = 90.0
const HALF_ALPHA: float = 0.5


function point(x: int, y: int) -> rl.Vector2:
    return rl.Vector2(x = float<-x, y = float<-y)


function gesture_name(gesture: int) -> str:
    if gesture == 1:
        return "Tap"
    if gesture == 2:
        return "Double Tap"
    if gesture == 4:
        return "Hold"
    if gesture == 8:
        return "Drag"
    if gesture == 16:
        return "Swipe Right"
    if gesture == 32:
        return "Swipe Left"
    if gesture == 64:
        return "Swipe Up"
    if gesture == 128:
        return "Swipe Down"
    if gesture == 256:
        return "Pinch In"
    if gesture == 512:
        return "Pinch Out"
    if gesture == 0:
        return "None"
    return "Unknown"


function gesture_color(gesture: int) -> rl.Color:
    if gesture == 1:
        return rl.BLUE
    if gesture == 2:
        return rl.SKYBLUE
    if gesture == 8:
        return rl.LIME
    if gesture == 16 or gesture == 32 or gesture == 64 or gesture == 128:
        return rl.RED
    if gesture == 256:
        return rl.VIOLET
    if gesture == 512:
        return rl.ORANGE
    return rl.BLACK


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - input gestures testbed")
    defer rl.close_window()

    let message_position = rl.Vector2(x = 160.0, y = 7.0)
    var last_gesture = 0
    let last_gesture_position = rl.Vector2(x = 165.0, y = 130.0)
    var gesture_log: array[int, GESTURE_LOG_SIZE] = zero[array[int, GESTURE_LOG_SIZE]]
    var gesture_log_index = GESTURE_LOG_SIZE
    var previous_gesture = 0
    var log_mode = 1
    var active_gesture_color = rl.BLACK
    let log_button1 = rl.Rectangle(x = 53.0, y = 7.0, width = 48.0, height = 26.0)
    let log_button2 = rl.Rectangle(x = 108.0, y = 7.0, width = 36.0, height = 26.0)
    let gesture_log_position = rl.Vector2(x = 10.0, y = 10.0)
    let angle_length: float = 90.0
    var current_angle_degrees: float = 0.0
    var final_vector = rl.Vector2(x = 0.0, y = 0.0)
    let protractor_position = rl.Vector2(x = 266.0, y = 315.0)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let current_gesture = rl.get_gesture_detected()
        let current_drag_degrees = rl.get_gesture_drag_angle()
        let current_pinch_degrees = rl.get_gesture_pinch_angle()
        let touch_count = rl.get_touch_point_count()

        if current_gesture != 0 and current_gesture != 4 and current_gesture != previous_gesture:
            last_gesture = current_gesture

        if rl.is_mouse_button_released(rl.MouseButton.MOUSE_BUTTON_LEFT):
            if rl.check_collision_point_rec(rl.get_mouse_position(), log_button1):
                if log_mode == 3:
                    log_mode = 2
                else if log_mode == 2:
                    log_mode = 3
                else if log_mode == 1:
                    log_mode = 0
                else:
                    log_mode = 1
            else if rl.check_collision_point_rec(rl.get_mouse_position(), log_button2):
                if log_mode == 3:
                    log_mode = 1
                else if log_mode == 2:
                    log_mode = 0
                else if log_mode == 1:
                    log_mode = 3
                else:
                    log_mode = 2

        var fill_log = false
        if current_gesture != 0:
            if log_mode == 3:
                fill_log = ((current_gesture != 4 and current_gesture != previous_gesture) or current_gesture < 3)
            else if log_mode == 2:
                fill_log = current_gesture != 4
            else if log_mode == 1:
                fill_log = current_gesture != previous_gesture
            else:
                fill_log = true

        if fill_log:
            previous_gesture = current_gesture
            active_gesture_color = gesture_color(current_gesture)
            if gesture_log_index <= 0:
                gesture_log_index = GESTURE_LOG_SIZE
            gesture_log_index -= 1
            gesture_log[gesture_log_index] = current_gesture

        if current_gesture > 255:
            current_angle_degrees = current_pinch_degrees
        else if current_gesture > 15:
            current_angle_degrees = current_drag_degrees
        else if current_gesture > 0:
            current_angle_degrees = 0.0

        let current_angle_radians = (current_angle_degrees + ANGLE_OFFSET) * rl.PI / DEGREE_DIVISOR
        final_vector = rl.Vector2(
            x = angle_length * float<-math.sin(double<-current_angle_radians) + protractor_position.x,
            y = angle_length * float<-math.cos(double<-current_angle_radians) + protractor_position.y
        )

        var touch_positions: array[rl.Vector2, MAX_TOUCH_COUNT] = zero[array[rl.Vector2, MAX_TOUCH_COUNT]]
        var mouse_position = rl.Vector2(x = 0.0, y = 0.0)
        if current_gesture != 0:
            if touch_count != 0:
                var index = 0
                while index < touch_count:
                    touch_positions[index] = rl.get_touch_position(index)
                    index += 1
            else:
                mouse_position = rl.get_mouse_position()

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        let message_x = int<-message_position.x
        let message_y = int<-message_position.y
        let last_x = int<-last_gesture_position.x
        let last_y = int<-last_gesture_position.y
        let protractor_x = int<-protractor_position.x
        let protractor_y = int<-protractor_position.y

        rl.draw_text("*", message_x + 5, message_y + 5, 10, rl.BLACK)
        rl.draw_text(
            "Example optimized for Web/HTML5\non Smartphones with Touch Screen.",
            message_x + 15,
            message_y + 5,
            10,
            rl.BLACK
        )
        rl.draw_text("*", message_x + 5, message_y + 35, 10, rl.BLACK)
        rl.draw_text(
            "While running on Desktop Web Browsers,\ninspect and turn on Touch Emulation.",
            message_x + 15,
            message_y + 35,
            10,
            rl.BLACK
        )

        rl.draw_text("Last gesture", last_x + 33, last_y - 47, 20, rl.BLACK)
        rl.draw_text("Swipe         Tap       Pinch  Touch", last_x + 17, last_y - 18, 10, rl.BLACK)
        rl.draw_rectangle(
            last_x + 20,
            last_y,
            20,
            20,
            if last_gesture == int<-rl.Gesture.GESTURE_SWIPE_UP: rl.RED else: rl.LIGHTGRAY
        )
        rl.draw_rectangle(
            last_x,
            last_y + 20,
            20,
            20,
            if last_gesture == int<-rl.Gesture.GESTURE_SWIPE_LEFT: rl.RED else: rl.LIGHTGRAY
        )
        rl.draw_rectangle(
            last_x + 40,
            last_y + 20,
            20,
            20,
            if last_gesture == int<-rl.Gesture.GESTURE_SWIPE_RIGHT: rl.RED else: rl.LIGHTGRAY
        )
        rl.draw_rectangle(
            last_x + 20,
            last_y + 40,
            20,
            20,
            if last_gesture == int<-rl.Gesture.GESTURE_SWIPE_DOWN: rl.RED else: rl.LIGHTGRAY
        )
        rl.draw_circle(
            last_x + 80,
            last_y + 16,
            10.0,
            if last_gesture == int<-rl.Gesture.GESTURE_TAP: rl.BLUE else: rl.LIGHTGRAY
        )
        rl.draw_ring(
            point(last_x + 103, last_y + 16),
            6.0,
            11.0,
            0.0,
            360.0,
            0,
            if last_gesture == int<-rl.Gesture.GESTURE_DRAG: rl.LIME else: rl.LIGHTGRAY
        )
        rl.draw_circle(
            last_x + 80,
            last_y + 43,
            10.0,
            if last_gesture == int<-rl.Gesture.GESTURE_DOUBLETAP: rl.SKYBLUE else: rl.LIGHTGRAY
        )
        rl.draw_circle(
            last_x + 103,
            last_y + 43,
            10.0,
            if last_gesture == int<-rl.Gesture.GESTURE_DOUBLETAP: rl.SKYBLUE else: rl.LIGHTGRAY
        )
        rl.draw_triangle(
            point(last_x + 122, last_y + 16),
            point(last_x + 137, last_y + 26),
            point(last_x + 137, last_y + 6),
            if last_gesture == int<-rl.Gesture.GESTURE_PINCH_OUT: rl.ORANGE else: rl.LIGHTGRAY
        )
        rl.draw_triangle(
            point(last_x + 147, last_y + 6),
            point(last_x + 147, last_y + 26),
            point(last_x + 162, last_y + 16),
            if last_gesture == int<-rl.Gesture.GESTURE_PINCH_OUT: rl.ORANGE else: rl.LIGHTGRAY
        )
        rl.draw_triangle(
            point(last_x + 125, last_y + 33),
            point(last_x + 125, last_y + 53),
            point(last_x + 140, last_y + 43),
            if last_gesture == int<-rl.Gesture.GESTURE_PINCH_IN: rl.VIOLET else: rl.LIGHTGRAY
        )
        rl.draw_triangle(
            point(last_x + 144, last_y + 43),
            point(last_x + 159, last_y + 53),
            point(last_x + 159, last_y + 33),
            if last_gesture == int<-rl.Gesture.GESTURE_PINCH_IN: rl.VIOLET else: rl.LIGHTGRAY
        )

        var index = 0
        while index < 4:
            rl.draw_circle(
                last_x + 180,
                last_y + 7 + index * 15,
                5.0,
                if touch_count <= index: rl.LIGHTGRAY else: active_gesture_color
            )
            index += 1

        rl.draw_text("Log", int<-gesture_log_position.x, int<-gesture_log_position.y, 20, rl.BLACK)
        index = 0
        var log_scan = gesture_log_index % GESTURE_LOG_SIZE
        while index < GESTURE_LOG_SIZE:
            let entry_gesture = gesture_log[log_scan]
            rl.draw_text(
                gesture_name(entry_gesture),
                int<-gesture_log_position.x,
                int<-gesture_log_position.y + 410 - index * 20,
                20,
                if index == 0: active_gesture_color else: rl.LIGHTGRAY
            )
            log_scan = (log_scan + 1) % GESTURE_LOG_SIZE
            index += 1

        var log_button1_color = rl.GRAY
        var log_button2_color = rl.GRAY
        if log_mode == 3:
            log_button1_color = rl.MAROON
            log_button2_color = rl.MAROON
        else if log_mode == 2:
            log_button2_color = rl.MAROON
        else if log_mode == 1:
            log_button1_color = rl.MAROON

        rl.draw_rectangle_rec(log_button1, log_button1_color)
        rl.draw_text("Hide", int<-log_button1.x + 7, int<-log_button1.y + 3, 10, rl.WHITE)
        rl.draw_text("Repeat", int<-log_button1.x + 7, int<-log_button1.y + 13, 10, rl.WHITE)
        rl.draw_rectangle_rec(log_button2, log_button2_color)
        rl.draw_text("Hide", int<-log_button1.x + 62, int<-log_button1.y + 3, 10, rl.WHITE)
        rl.draw_text("Hold", int<-log_button1.x + 62, int<-log_button1.y + 13, 10, rl.WHITE)

        rl.draw_text("Angle", protractor_x + 55, protractor_y + 76, 10, rl.BLACK)
        let angle_string = rl.text_format("%f", current_angle_degrees)
        let angle_string_dot = rl.text_find_index(angle_string, ".")
        let angle_string_trim = rl.text_subtext(angle_string, 0, angle_string_dot + 3)
        rl.draw_text(angle_string_trim, protractor_x + 55, protractor_y + 92, 20, active_gesture_color)
        rl.draw_circle_v(protractor_position, 80.0, rl.WHITE)
        rl.draw_line_ex(
            point(protractor_x - 90, protractor_y),
            point(protractor_x + 90, protractor_y),
            3.0,
            rl.LIGHTGRAY
        )
        rl.draw_line_ex(
            point(protractor_x, protractor_y - 90),
            point(protractor_x, protractor_y + 90),
            3.0,
            rl.LIGHTGRAY
        )
        rl.draw_line_ex(
            point(protractor_x - 80, protractor_y - 45),
            point(protractor_x + 80, protractor_y + 45),
            3.0,
            rl.GREEN
        )
        rl.draw_line_ex(
            point(protractor_x - 80, protractor_y + 45),
            point(protractor_x + 80, protractor_y - 45),
            3.0,
            rl.GREEN
        )
        rl.draw_text("0", protractor_x + 96, protractor_y - 9, 20, rl.BLACK)
        rl.draw_text("30", protractor_x + 74, protractor_y - 68, 20, rl.BLACK)
        rl.draw_text("90", protractor_x - 11, protractor_y - 110, 20, rl.BLACK)
        rl.draw_text("150", protractor_x - 100, protractor_y - 68, 20, rl.BLACK)
        rl.draw_text("180", protractor_x - 124, protractor_y - 9, 20, rl.BLACK)
        rl.draw_text("210", protractor_x - 100, protractor_y + 50, 20, rl.BLACK)
        rl.draw_text("270", protractor_x - 18, protractor_y + 92, 20, rl.BLACK)
        rl.draw_text("330", protractor_x + 72, protractor_y + 50, 20, rl.BLACK)
        if current_angle_degrees != 0.0:
            rl.draw_line_ex(protractor_position, final_vector, 3.0, active_gesture_color)

        if current_gesture != 0:
            if touch_count != 0:
                index = 0
                while index < touch_count:
                    rl.draw_circle_v(touch_positions[index], 50.0, rl.fade(active_gesture_color, HALF_ALPHA))
                    rl.draw_circle_v(touch_positions[index], 5.0, active_gesture_color)
                    index += 1

                if touch_count == 2:
                    rl.draw_line_ex(
                        touch_positions[0],
                        touch_positions[1],
                        if current_gesture == 512: 8.0 else: 12.0,
                        active_gesture_color
                    )
            else:
                rl.draw_circle_v(mouse_position, 35.0, rl.fade(active_gesture_color, HALF_ALPHA))
                rl.draw_circle_v(mouse_position, 5.0, active_gesture_color)

        rl.end_drawing()

    return 0
