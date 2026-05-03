module examples.raylib.shapes.shapes_digital_clock

import std.c.libm as math
import std.c.raylib as rl
import std.c.time as ctime
import std.math as mt_math

struct ClockHand:
    value: i32
    angle: f32
    length: i32
    thickness: i32
    color: rl.Color

struct Clock:
    second: ClockHand
    minute: ClockHand
    hour: ClockHand

const clock_analog: i32 = 0
const clock_digital: i32 = 1
const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shapes] example - digital clock"
const time_format: cstr = c"%H:%M:%S"
const clock_mode_format: cstr = c"Press [SPACE] to switch clock mode: %s"


def clock_hand(angle: f32, length: i32, thickness: i32, color: rl.Color) -> ClockHand:
    return ClockHand(value = 0, angle = angle, length = length, thickness = thickness, color = color)


def digit_value(digit: char) -> i32:
    return i32<-digit - 48


def parse_two_digits(time_buffer: array[char, 9], index: i32) -> i32:
    return digit_value(time_buffer[index]) * 10 + digit_value(time_buffer[index + 1])


def update_clock(clock: ref[Clock], time_buffer: ref[array[char, 9]]) -> void:
    var now: ctime.time_t = 0
    now = ctime.time(ptr_of(ref_of(now)))
    let tm_info = ctime.localtime(ptr_of(ref_of(now)))

    unsafe:
        ctime.strftime(ptr_of(ref_of(read(time_buffer)[0])), 9, time_format, tm_info)

    clock.hour.value = parse_two_digits(read(time_buffer), 0)
    clock.minute.value = parse_two_digits(read(time_buffer), 3)
    clock.second.value = parse_two_digits(read(time_buffer), 6)

    clock.hour.angle = f32<-(clock.hour.value % 12) * 180.0 / 6.0
    clock.hour.angle += f32<-(clock.minute.value % 60) * 30.0 / 60.0
    clock.hour.angle -= 90.0

    clock.minute.angle = f32<-(clock.minute.value % 60) * 6.0
    clock.minute.angle += f32<-(clock.second.value % 60) * 6.0 / 60.0
    clock.minute.angle -= 90.0

    clock.second.angle = f32<-(clock.second.value % 60) * 6.0
    clock.second.angle -= 90.0


def draw_clock_analog(clock: Clock, position: rl.Vector2) -> void:
    rl.DrawCircleV(position, f32<-clock.second.length + 40.0, rl.LIGHTGRAY)
    rl.DrawCircleV(position, 12.0, rl.GRAY)

    for index in range(0, 60):
        let tick_angle = 6.0 * f32<-index - 90.0
        let inner_offset = if index % 5 != 0: 10.0 else: 6.0
        rl.DrawLineEx(
            rl.Vector2(
                x = position.x + (f32<-clock.second.length + inner_offset) * math.cosf(mt_math.deg2rad * tick_angle),
                y = position.y + (f32<-clock.second.length + inner_offset) * math.sinf(mt_math.deg2rad * tick_angle),
            ),
            rl.Vector2(
                x = position.x + (f32<-clock.second.length + 20.0) * math.cosf(mt_math.deg2rad * tick_angle),
                y = position.y + (f32<-clock.second.length + 20.0) * math.sinf(mt_math.deg2rad * tick_angle),
            ),
            if index % 5 != 0: 1.0 else: 3.0,
            rl.DARKGRAY,
        )

    rl.DrawRectanglePro(
        rl.Rectangle(x = position.x, y = position.y, width = clock.second.length, height = clock.second.thickness),
        rl.Vector2(x = 0.0, y = clock.second.thickness / 2.0),
        clock.second.angle,
        clock.second.color,
    )
    rl.DrawRectanglePro(
        rl.Rectangle(x = position.x, y = position.y, width = clock.minute.length, height = clock.minute.thickness),
        rl.Vector2(x = 0.0, y = clock.minute.thickness / 2.0),
        clock.minute.angle,
        clock.minute.color,
    )
    rl.DrawRectanglePro(
        rl.Rectangle(x = position.x, y = position.y, width = clock.hour.length, height = clock.hour.thickness),
        rl.Vector2(x = 0.0, y = clock.hour.thickness / 2.0),
        clock.hour.angle,
        clock.hour.color,
    )


def draw_display_segment(center: rl.Vector2, length: i32, thick: i32, vertical: bool, color: rl.Color) -> void:
    if not vertical:
        var segment_points = array[rl.Vector2, 6](
            rl.Vector2(x = center.x - f32<-length / 2.0 - f32<-thick / 2.0, y = center.y),
            rl.Vector2(x = center.x - f32<-length / 2.0, y = center.y + f32<-thick / 2.0),
            rl.Vector2(x = center.x - f32<-length / 2.0, y = center.y - f32<-thick / 2.0),
            rl.Vector2(x = center.x + f32<-length / 2.0, y = center.y + f32<-thick / 2.0),
            rl.Vector2(x = center.x + f32<-length / 2.0, y = center.y - f32<-thick / 2.0),
            rl.Vector2(x = center.x + f32<-length / 2.0 + f32<-thick / 2.0, y = center.y),
        )
        rl.DrawTriangleStrip(ptr_of(ref_of(segment_points[0])), 6, color)
    else:
        var segment_points = array[rl.Vector2, 6](
            rl.Vector2(x = center.x, y = center.y - f32<-length / 2.0 - f32<-thick / 2.0),
            rl.Vector2(x = center.x - f32<-thick / 2.0, y = center.y - f32<-length / 2.0),
            rl.Vector2(x = center.x + f32<-thick / 2.0, y = center.y - f32<-length / 2.0),
            rl.Vector2(x = center.x - f32<-thick / 2.0, y = center.y + f32<-length / 2.0),
            rl.Vector2(x = center.x + f32<-thick / 2.0, y = center.y + f32<-length / 2.0),
            rl.Vector2(x = center.x, y = center.y + f32<-length / 2.0 + f32<-thick / 2.0),
        )
        rl.DrawTriangleStrip(ptr_of(ref_of(segment_points[0])), 6, color)


def draw_7s_display(position: rl.Vector2, segments: i32, color_on: rl.Color, color_off: rl.Color) -> void:
    let segment_len = 60
    let segment_thick = 20
    let offset_y_adjust = f32<-segment_thick * 0.3

    draw_display_segment(
        rl.Vector2(x = position.x + f32<-segment_thick + f32<-segment_len / 2.0, y = position.y + f32<-segment_thick),
        segment_len,
        segment_thick,
        false,
        if (segments & 1) != 0: color_on else: color_off,
    )
    draw_display_segment(
        rl.Vector2(x = position.x + f32<-segment_thick + f32<-segment_len + f32<-segment_thick / 2.0, y = position.y + 2.0 * f32<-segment_thick + f32<-segment_len / 2.0 - offset_y_adjust),
        segment_len,
        segment_thick,
        true,
        if (segments & 2) != 0: color_on else: color_off,
    )
    draw_display_segment(
        rl.Vector2(x = position.x + f32<-segment_thick + f32<-segment_len + f32<-segment_thick / 2.0, y = position.y + 4.0 * f32<-segment_thick + f32<-segment_len + f32<-segment_len / 2.0 - 3.0 * offset_y_adjust),
        segment_len,
        segment_thick,
        true,
        if (segments & 4) != 0: color_on else: color_off,
    )
    draw_display_segment(
        rl.Vector2(x = position.x + f32<-segment_thick + f32<-segment_len / 2.0, y = position.y + 5.0 * f32<-segment_thick + 2.0 * f32<-segment_len - 4.0 * offset_y_adjust),
        segment_len,
        segment_thick,
        false,
        if (segments & 8) != 0: color_on else: color_off,
    )
    draw_display_segment(
        rl.Vector2(x = position.x + f32<-segment_thick / 2.0, y = position.y + 4.0 * f32<-segment_thick + f32<-segment_len + f32<-segment_len / 2.0 - 3.0 * offset_y_adjust),
        segment_len,
        segment_thick,
        true,
        if (segments & 16) != 0: color_on else: color_off,
    )
    draw_display_segment(
        rl.Vector2(x = position.x + f32<-segment_thick / 2.0, y = position.y + 2.0 * f32<-segment_thick + f32<-segment_len / 2.0 - offset_y_adjust),
        segment_len,
        segment_thick,
        true,
        if (segments & 32) != 0: color_on else: color_off,
    )
    draw_display_segment(
        rl.Vector2(x = position.x + f32<-segment_thick + f32<-segment_len / 2.0, y = position.y + 3.0 * f32<-segment_thick + f32<-segment_len - 2.0 * offset_y_adjust),
        segment_len,
        segment_thick,
        false,
        if (segments & 64) != 0: color_on else: color_off,
    )


def draw_display_value(position: rl.Vector2, value: i32, color_on: rl.Color, color_off: rl.Color) -> void:
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
    let color_off = rl.Fade(rl.LIGHTGRAY, 0.3)

    draw_display_value(position, clock.hour.value / 10, rl.RED, color_off)
    draw_display_value(rl.Vector2(x = position.x + 120.0, y = position.y), clock.hour.value % 10, rl.RED, color_off)

    rl.DrawCircle(i32<-position.x + 240, i32<-position.y + 70, 12.0, if clock.second.value % 2 != 0: rl.RED else: color_off)
    rl.DrawCircle(i32<-position.x + 240, i32<-position.y + 150, 12.0, if clock.second.value % 2 != 0: rl.RED else: color_off)

    draw_display_value(rl.Vector2(x = position.x + 260.0, y = position.y), clock.minute.value / 10, rl.RED, color_off)
    draw_display_value(rl.Vector2(x = position.x + 380.0, y = position.y), clock.minute.value % 10, rl.RED, color_off)

    rl.DrawCircle(i32<-position.x + 500, i32<-position.y + 70, 12.0, if clock.second.value % 2 != 0: rl.RED else: color_off)
    rl.DrawCircle(i32<-position.x + 500, i32<-position.y + 150, 12.0, if clock.second.value % 2 != 0: rl.RED else: color_off)

    draw_display_value(rl.Vector2(x = position.x + 520.0, y = position.y), clock.second.value / 10, rl.RED, color_off)
    draw_display_value(rl.Vector2(x = position.x + 640.0, y = position.y), clock.second.value % 10, rl.RED, color_off)


def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var clock_mode = clock_digital
    var clock = Clock(
        second = clock_hand(45.0, 140, 3, rl.MAROON),
        minute = clock_hand(10.0, 130, 7, rl.DARKGRAY),
        hour = clock_hand(0.0, 100, 7, rl.BLACK),
    )
    var time_buffer = zero[array[char, 9]]()

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            if clock_mode == clock_digital:
                clock_mode = clock_analog
            else:
                clock_mode = clock_digital

        update_clock(ref_of(clock), ref_of(time_buffer))

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        if clock_mode == clock_analog:
            draw_clock_analog(clock, rl.Vector2(x = 400.0, y = 240.0))
        else:
            draw_clock_digital(clock, rl.Vector2(x = 30.0, y = 60.0))
            unsafe:
                let clock_time = cstr<-ptr_of(ref_of(time_buffer[0]))
                rl.DrawText(clock_time, rl.GetScreenWidth() / 2 - rl.MeasureText(clock_time, 150) / 2, 300, 150, rl.BLACK)

        rl.DrawText(
            rl.TextFormat(clock_mode_format, if clock_mode == clock_digital: c"DIGITAL CLOCK" else: c"ANALOGUE CLOCK"),
            10,
            10,
            20,
            rl.DARKGRAY,
        )

    return 0
