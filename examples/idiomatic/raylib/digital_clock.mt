module examples.idiomatic.raylib.digital_clock

import std.raylib as rl
import std.raylib.math as math
import std.time as time

struct ClockHand:
    value: int
    angle: float
    length: int
    thickness: int
    color: rl.Color

struct Clock:
    second: ClockHand
    minute: ClockHand
    hour: ClockHand

const clock_analog: int = 0
const clock_digital: int = 1
const screen_width: int = 800
const screen_height: int = 450


def clock_hand(angle: float, length: int, thickness: int, color: rl.Color) -> ClockHand:
    return ClockHand(value = 0, angle = angle, length = length, thickness = thickness, color = color)


def apply_clock_time(clock: ref[Clock], current: time.ClockTime) -> void:
    clock.hour.value = current.hour
    clock.minute.value = current.minute
    clock.second.value = current.second

    clock.hour.angle = float<-(clock.hour.value % 12) * 180.0 / 6.0
    clock.hour.angle += float<-(clock.minute.value % 60) * 30.0 / 60.0
    clock.hour.angle -= 90.0

    clock.minute.angle = float<-(clock.minute.value % 60) * 6.0
    clock.minute.angle += float<-(clock.second.value % 60) * 6.0 / 60.0
    clock.minute.angle -= 90.0

    clock.second.angle = float<-(clock.second.value % 60) * 6.0
    clock.second.angle -= 90.0


def update_clock(clock: ref[Clock]) -> void:
    let current = time.local_clock()
    if current.is_ok:
        apply_clock_time(clock, current.value)


def draw_clock_analog(clock: Clock, position: rl.Vector2) -> void:
    rl.draw_circle_v(position, float<-clock.second.length + 40.0, rl.LIGHTGRAY)
    rl.draw_circle_v(position, 12.0, rl.GRAY)

    for index in 0..60:
        let tick_angle = 6.0 * float<-index - 90.0
        let inner_offset = if index % 5 != 0: 10.0 else: 6.0
        rl.draw_line_ex(
            rl.Vector2(
                x = position.x + (float<-clock.second.length + inner_offset) * math.cos(math.deg2rad * tick_angle),
                y = position.y + (float<-clock.second.length + inner_offset) * math.sin(math.deg2rad * tick_angle),
            ),
            rl.Vector2(
                x = position.x + (float<-clock.second.length + 20.0) * math.cos(math.deg2rad * tick_angle),
                y = position.y + (float<-clock.second.length + 20.0) * math.sin(math.deg2rad * tick_angle),
            ),
            if index % 5 != 0: 1.0 else: 3.0,
            rl.DARKGRAY,
        )

    rl.draw_rectangle_pro(
        rl.Rectangle(x = position.x, y = position.y, width = float<-clock.second.length, height = float<-clock.second.thickness),
        rl.Vector2(x = 0.0, y = float<-clock.second.thickness / 2.0),
        clock.second.angle,
        clock.second.color,
    )
    rl.draw_rectangle_pro(
        rl.Rectangle(x = position.x, y = position.y, width = float<-clock.minute.length, height = float<-clock.minute.thickness),
        rl.Vector2(x = 0.0, y = float<-clock.minute.thickness / 2.0),
        clock.minute.angle,
        clock.minute.color,
    )
    rl.draw_rectangle_pro(
        rl.Rectangle(x = position.x, y = position.y, width = float<-clock.hour.length, height = float<-clock.hour.thickness),
        rl.Vector2(x = 0.0, y = float<-clock.hour.thickness / 2.0),
        clock.hour.angle,
        clock.hour.color,
    )


def draw_segment_triangles(points: array[rl.Vector2, 6], color: rl.Color) -> void:
    rl.draw_triangle(points[0], points[1], points[2], color)
    rl.draw_triangle(points[2], points[1], points[3], color)
    rl.draw_triangle(points[2], points[3], points[4], color)
    rl.draw_triangle(points[4], points[3], points[5], color)


def draw_display_segment(center: rl.Vector2, length: int, thick: int, vertical: bool, color: rl.Color) -> void:
    let half_length = float<-length / 2.0
    let half_thick = float<-thick / 2.0
    if not vertical:
        draw_segment_triangles(array[rl.Vector2, 6](
            rl.Vector2(x = center.x - half_length - half_thick, y = center.y),
            rl.Vector2(x = center.x - half_length, y = center.y + half_thick),
            rl.Vector2(x = center.x - half_length, y = center.y - half_thick),
            rl.Vector2(x = center.x + half_length, y = center.y + half_thick),
            rl.Vector2(x = center.x + half_length, y = center.y - half_thick),
            rl.Vector2(x = center.x + half_length + half_thick, y = center.y),
        ), color)
    else:
        draw_segment_triangles(array[rl.Vector2, 6](
            rl.Vector2(x = center.x, y = center.y - half_length - half_thick),
            rl.Vector2(x = center.x - half_thick, y = center.y - half_length),
            rl.Vector2(x = center.x + half_thick, y = center.y - half_length),
            rl.Vector2(x = center.x - half_thick, y = center.y + half_length),
            rl.Vector2(x = center.x + half_thick, y = center.y + half_length),
            rl.Vector2(x = center.x, y = center.y + half_length + half_thick),
        ), color)


def draw_7s_display(position: rl.Vector2, segments: int, color_on: rl.Color, color_off: rl.Color) -> void:
    let segment_len = 60
    let segment_thick = 20
    let offset_y_adjust = float<-segment_thick * 0.3

    draw_display_segment(
        rl.Vector2(x = position.x + float<-segment_thick + float<-segment_len / 2.0, y = position.y + float<-segment_thick),
        segment_len,
        segment_thick,
        false,
        if (segments & 1) != 0: color_on else: color_off,
    )
    draw_display_segment(
        rl.Vector2(x = position.x + float<-segment_thick + float<-segment_len + float<-segment_thick / 2.0, y = position.y + 2.0 * float<-segment_thick + float<-segment_len / 2.0 - offset_y_adjust),
        segment_len,
        segment_thick,
        true,
        if (segments & 2) != 0: color_on else: color_off,
    )
    draw_display_segment(
        rl.Vector2(x = position.x + float<-segment_thick + float<-segment_len + float<-segment_thick / 2.0, y = position.y + 4.0 * float<-segment_thick + float<-segment_len + float<-segment_len / 2.0 - 3.0 * offset_y_adjust),
        segment_len,
        segment_thick,
        true,
        if (segments & 4) != 0: color_on else: color_off,
    )
    draw_display_segment(
        rl.Vector2(x = position.x + float<-segment_thick + float<-segment_len / 2.0, y = position.y + 5.0 * float<-segment_thick + 2.0 * float<-segment_len - 4.0 * offset_y_adjust),
        segment_len,
        segment_thick,
        false,
        if (segments & 8) != 0: color_on else: color_off,
    )
    draw_display_segment(
        rl.Vector2(x = position.x + float<-segment_thick / 2.0, y = position.y + 4.0 * float<-segment_thick + float<-segment_len + float<-segment_len / 2.0 - 3.0 * offset_y_adjust),
        segment_len,
        segment_thick,
        true,
        if (segments & 16) != 0: color_on else: color_off,
    )
    draw_display_segment(
        rl.Vector2(x = position.x + float<-segment_thick / 2.0, y = position.y + 2.0 * float<-segment_thick + float<-segment_len / 2.0 - offset_y_adjust),
        segment_len,
        segment_thick,
        true,
        if (segments & 32) != 0: color_on else: color_off,
    )
    draw_display_segment(
        rl.Vector2(x = position.x + float<-segment_thick + float<-segment_len / 2.0, y = position.y + 3.0 * float<-segment_thick + float<-segment_len - 2.0 * offset_y_adjust),
        segment_len,
        segment_thick,
        false,
        if (segments & 64) != 0: color_on else: color_off,
    )


def draw_display_value(position: rl.Vector2, value: int, color_on: rl.Color, color_off: rl.Color) -> void:
    if value == 0:
        draw_7s_display(position, 63, color_on, color_off)
    elif value == 1:
        draw_7s_display(position, 6, color_on, color_off)
    elif value == 2:
        draw_7s_display(position, 91, color_on, color_off)
    elif value == 3:
        draw_7s_display(position, 79, color_on, color_off)
    elif value == 4:
        draw_7s_display(position, 102, color_on, color_off)
    elif value == 5:
        draw_7s_display(position, 109, color_on, color_off)
    elif value == 6:
        draw_7s_display(position, 125, color_on, color_off)
    elif value == 7:
        draw_7s_display(position, 7, color_on, color_off)
    elif value == 8:
        draw_7s_display(position, 127, color_on, color_off)
    elif value == 9:
        draw_7s_display(position, 111, color_on, color_off)


def draw_clock_digital(clock: Clock, position: rl.Vector2) -> void:
    let color_off = rl.fade(rl.LIGHTGRAY, 0.3)

    draw_display_value(position, clock.hour.value / 10, rl.RED, color_off)
    draw_display_value(rl.Vector2(x = position.x + 120.0, y = position.y), clock.hour.value % 10, rl.RED, color_off)

    rl.draw_circle(int<-position.x + 240, int<-position.y + 70, 12.0, if clock.second.value % 2 != 0: rl.RED else: color_off)
    rl.draw_circle(int<-position.x + 240, int<-position.y + 150, 12.0, if clock.second.value % 2 != 0: rl.RED else: color_off)

    draw_display_value(rl.Vector2(x = position.x + 260.0, y = position.y), clock.minute.value / 10, rl.RED, color_off)
    draw_display_value(rl.Vector2(x = position.x + 380.0, y = position.y), clock.minute.value % 10, rl.RED, color_off)

    rl.draw_circle(int<-position.x + 500, int<-position.y + 70, 12.0, if clock.second.value % 2 != 0: rl.RED else: color_off)
    rl.draw_circle(int<-position.x + 500, int<-position.y + 150, 12.0, if clock.second.value % 2 != 0: rl.RED else: color_off)

    draw_display_value(rl.Vector2(x = position.x + 520.0, y = position.y), clock.second.value / 10, rl.RED, color_off)
    draw_display_value(rl.Vector2(x = position.x + 640.0, y = position.y), clock.second.value % 10, rl.RED, color_off)


def main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(screen_width, screen_height, "Milk Tea Digital Clock")
    defer rl.close_window()

    var clock_mode = clock_digital
    var clock = Clock(
        second = clock_hand(45.0, 140, 3, rl.MAROON),
        minute = clock_hand(10.0, 130, 7, rl.DARKGRAY),
        hour = clock_hand(0.0, 100, 7, rl.BLACK),
    )

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            if clock_mode == clock_digital:
                clock_mode = clock_analog
            else:
                clock_mode = clock_digital

        update_clock(ref_of(clock))

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        if clock_mode == clock_analog:
            draw_clock_analog(clock, rl.Vector2(x = 400.0, y = 240.0))
        else:
            draw_clock_digital(clock, rl.Vector2(x = 30.0, y = 60.0))
            let clock_time = rl.text_format_int_int_int("%02d:%02d:%02d", clock.hour.value, clock.minute.value, clock.second.value)
            rl.draw_text(clock_time, rl.get_screen_width() / 2 - rl.measure_text(clock_time, 150) / 2, 300, 150, rl.BLACK)

        rl.draw_text(
            rl.text_format_cstr("Press [SPACE] to switch clock mode: %s", if clock_mode == clock_digital: "DIGITAL CLOCK" else: "ANALOGUE CLOCK"),
            10,
            10,
            20,
            rl.DARKGRAY,
        )

    return 0
