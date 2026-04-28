module examples.idiomatic.raylib.digital_clock

import std.raylib as rl
import std.raylib.math as math
import std.time as time

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

def clock_hand(angle: f32, length: i32, thickness: i32, color: rl.Color) -> ClockHand:
    return ClockHand(value = 0, angle = angle, length = length, thickness = thickness, color = color)

def apply_clock_time(clock: ref[Clock], current: time.ClockTime) -> void:
    value(clock).hour.value = current.hour
    value(clock).minute.value = current.minute
    value(clock).second.value = current.second

    value(clock).hour.angle = cast[f32](value(clock).hour.value % 12) * 180.0 / 6.0
    value(clock).hour.angle += cast[f32](value(clock).minute.value % 60) * 30.0 / 60.0
    value(clock).hour.angle -= 90.0

    value(clock).minute.angle = cast[f32](value(clock).minute.value % 60) * 6.0
    value(clock).minute.angle += cast[f32](value(clock).second.value % 60) * 6.0 / 60.0
    value(clock).minute.angle -= 90.0

    value(clock).second.angle = cast[f32](value(clock).second.value % 60) * 6.0
    value(clock).second.angle -= 90.0

def update_clock(clock: ref[Clock]) -> void:
    let current = time.local_clock()
    if current.is_ok:
        apply_clock_time(clock, current.value)

def draw_clock_analog(clock: Clock, position: rl.Vector2) -> void:
    rl.draw_circle_v(position, cast[f32](clock.second.length) + 40.0, rl.LIGHTGRAY)
    rl.draw_circle_v(position, 12.0, rl.GRAY)

    for index in range(0, 60):
        let tick_angle = 6.0 * cast[f32](index) - 90.0
        let inner_offset = if index % 5 != 0 then 10.0 else 6.0
        rl.draw_line_ex(
            rl.Vector2(
                x = position.x + (cast[f32](clock.second.length) + inner_offset) * math.cos(math.deg2rad * tick_angle),
                y = position.y + (cast[f32](clock.second.length) + inner_offset) * math.sin(math.deg2rad * tick_angle),
            ),
            rl.Vector2(
                x = position.x + (cast[f32](clock.second.length) + 20.0) * math.cos(math.deg2rad * tick_angle),
                y = position.y + (cast[f32](clock.second.length) + 20.0) * math.sin(math.deg2rad * tick_angle),
            ),
            if index % 5 != 0 then 1.0 else 3.0,
            rl.DARKGRAY,
        )

    rl.draw_rectangle_pro(
        rl.Rectangle(x = position.x, y = position.y, width = cast[f32](clock.second.length), height = cast[f32](clock.second.thickness)),
        rl.Vector2(x = 0.0, y = cast[f32](clock.second.thickness) / 2.0),
        clock.second.angle,
        clock.second.color,
    )
    rl.draw_rectangle_pro(
        rl.Rectangle(x = position.x, y = position.y, width = cast[f32](clock.minute.length), height = cast[f32](clock.minute.thickness)),
        rl.Vector2(x = 0.0, y = cast[f32](clock.minute.thickness) / 2.0),
        clock.minute.angle,
        clock.minute.color,
    )
    rl.draw_rectangle_pro(
        rl.Rectangle(x = position.x, y = position.y, width = cast[f32](clock.hour.length), height = cast[f32](clock.hour.thickness)),
        rl.Vector2(x = 0.0, y = cast[f32](clock.hour.thickness) / 2.0),
        clock.hour.angle,
        clock.hour.color,
    )

def draw_segment_triangles(points: array[rl.Vector2, 6], color: rl.Color) -> void:
    rl.draw_triangle(points[0], points[1], points[2], color)
    rl.draw_triangle(points[2], points[1], points[3], color)
    rl.draw_triangle(points[2], points[3], points[4], color)
    rl.draw_triangle(points[4], points[3], points[5], color)

def draw_display_segment(center: rl.Vector2, length: i32, thick: i32, vertical: bool, color: rl.Color) -> void:
    let half_length = cast[f32](length) / 2.0
    let half_thick = cast[f32](thick) / 2.0
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

def draw_7s_display(position: rl.Vector2, segments: i32, color_on: rl.Color, color_off: rl.Color) -> void:
    let segment_len = 60
    let segment_thick = 20
    let offset_y_adjust = cast[f32](segment_thick) * 0.3

    draw_display_segment(
        rl.Vector2(x = position.x + cast[f32](segment_thick) + cast[f32](segment_len) / 2.0, y = position.y + cast[f32](segment_thick)),
        segment_len,
        segment_thick,
        false,
        if (segments & 1) != 0 then color_on else color_off,
    )
    draw_display_segment(
        rl.Vector2(x = position.x + cast[f32](segment_thick) + cast[f32](segment_len) + cast[f32](segment_thick) / 2.0, y = position.y + 2.0 * cast[f32](segment_thick) + cast[f32](segment_len) / 2.0 - offset_y_adjust),
        segment_len,
        segment_thick,
        true,
        if (segments & 2) != 0 then color_on else color_off,
    )
    draw_display_segment(
        rl.Vector2(x = position.x + cast[f32](segment_thick) + cast[f32](segment_len) + cast[f32](segment_thick) / 2.0, y = position.y + 4.0 * cast[f32](segment_thick) + cast[f32](segment_len) + cast[f32](segment_len) / 2.0 - 3.0 * offset_y_adjust),
        segment_len,
        segment_thick,
        true,
        if (segments & 4) != 0 then color_on else color_off,
    )
    draw_display_segment(
        rl.Vector2(x = position.x + cast[f32](segment_thick) + cast[f32](segment_len) / 2.0, y = position.y + 5.0 * cast[f32](segment_thick) + 2.0 * cast[f32](segment_len) - 4.0 * offset_y_adjust),
        segment_len,
        segment_thick,
        false,
        if (segments & 8) != 0 then color_on else color_off,
    )
    draw_display_segment(
        rl.Vector2(x = position.x + cast[f32](segment_thick) / 2.0, y = position.y + 4.0 * cast[f32](segment_thick) + cast[f32](segment_len) + cast[f32](segment_len) / 2.0 - 3.0 * offset_y_adjust),
        segment_len,
        segment_thick,
        true,
        if (segments & 16) != 0 then color_on else color_off,
    )
    draw_display_segment(
        rl.Vector2(x = position.x + cast[f32](segment_thick) / 2.0, y = position.y + 2.0 * cast[f32](segment_thick) + cast[f32](segment_len) / 2.0 - offset_y_adjust),
        segment_len,
        segment_thick,
        true,
        if (segments & 32) != 0 then color_on else color_off,
    )
    draw_display_segment(
        rl.Vector2(x = position.x + cast[f32](segment_thick) + cast[f32](segment_len) / 2.0, y = position.y + 3.0 * cast[f32](segment_thick) + cast[f32](segment_len) - 2.0 * offset_y_adjust),
        segment_len,
        segment_thick,
        false,
        if (segments & 64) != 0 then color_on else color_off,
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
    let color_off = rl.fade(rl.LIGHTGRAY, 0.3)

    draw_display_value(position, clock.hour.value / 10, rl.RED, color_off)
    draw_display_value(rl.Vector2(x = position.x + 120.0, y = position.y), clock.hour.value % 10, rl.RED, color_off)

    rl.draw_circle(cast[i32](position.x) + 240, cast[i32](position.y) + 70, 12.0, if clock.second.value % 2 != 0 then rl.RED else color_off)
    rl.draw_circle(cast[i32](position.x) + 240, cast[i32](position.y) + 150, 12.0, if clock.second.value % 2 != 0 then rl.RED else color_off)

    draw_display_value(rl.Vector2(x = position.x + 260.0, y = position.y), clock.minute.value / 10, rl.RED, color_off)
    draw_display_value(rl.Vector2(x = position.x + 380.0, y = position.y), clock.minute.value % 10, rl.RED, color_off)

    rl.draw_circle(cast[i32](position.x) + 500, cast[i32](position.y) + 70, 12.0, if clock.second.value % 2 != 0 then rl.RED else color_off)
    rl.draw_circle(cast[i32](position.x) + 500, cast[i32](position.y) + 150, 12.0, if clock.second.value % 2 != 0 then rl.RED else color_off)

    draw_display_value(rl.Vector2(x = position.x + 520.0, y = position.y), clock.second.value / 10, rl.RED, color_off)
    draw_display_value(rl.Vector2(x = position.x + 640.0, y = position.y), clock.second.value % 10, rl.RED, color_off)

def main() -> i32:
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

        update_clock(addr(clock))

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        if clock_mode == clock_analog:
            draw_clock_analog(clock, rl.Vector2(x = 400.0, y = 240.0))
        else:
            draw_clock_digital(clock, rl.Vector2(x = 30.0, y = 60.0))
            let clock_time = rl.text_format_i32_i32_i32("%02d:%02d:%02d", clock.hour.value, clock.minute.value, clock.second.value)
            rl.draw_text(clock_time, rl.get_screen_width() / 2 - rl.measure_text(clock_time, 150) / 2, 300, 150, rl.BLACK)

        rl.draw_text(
            rl.text_format_cstr("Press [SPACE] to switch clock mode: %s", if clock_mode == clock_digital then "DIGITAL CLOCK" else "ANALOGUE CLOCK"),
            10,
            10,
            20,
            rl.DARKGRAY,
        )

    return 0
