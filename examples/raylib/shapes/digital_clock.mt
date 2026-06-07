import std.math as math
import std.raylib as rl
import std.str as text
import std.time as time

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const CLOCK_ANALOG: int = 0
const CLOCK_DIGITAL: int = 1
const DEG_TO_RAD: float = rl.PI / 180.0


function parse_ascii_digit(value: ubyte) -> int:
    return int<-(value - ubyte<-48)


function parse_two_digits(value_text: str, offset: ptr_uint) -> int:
    return parse_ascii_digit(value_text.byte_at(offset)) * 10 + parse_ascii_digit(value_text.byte_at(offset + ptr_uint<-1))


function blinking_separator_color(second_value: int, on_color: rl.Color, off_color: rl.Color) -> rl.Color:
    if second_value % 2 == 1:
        return on_color

    return off_color


function segment_color(segments: int, mask: int, color_on: rl.Color, color_off: rl.Color) -> rl.Color:
    if (segments & mask) != 0:
        return color_on

    return color_off

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


function update_clock(clock: ref[Clock]) -> void:
    let now = time.now()
    var time_buffer = zero[array[char, 7]]
    if time.format_local_time_into(ptr_of(time_buffer[0]), ptr_uint<-7, "%H%M%S", now) == 0:
        return

    let clock_text = text.chars_as_str(ptr_of(time_buffer[0]))
    let second_value = parse_two_digits(clock_text, ptr_uint<-4)
    let minute_value = parse_two_digits(clock_text, ptr_uint<-2)
    let hour_value = parse_two_digits(clock_text, ptr_uint<-0)

    read(clock).second.value = second_value
    read(clock).minute.value = minute_value
    read(clock).hour.value = hour_value

    read(clock).hour.angle = float<-((hour_value % 12) * 180.0 / 6.0)
    read(clock).hour.angle += float<-((minute_value % 60) * 30.0 / 60.0)
    read(clock).hour.angle -= 90.0

    read(clock).minute.angle = float<-((minute_value % 60) * 6.0)
    read(clock).minute.angle += float<-((second_value % 60) * 6.0 / 60.0)
    read(clock).minute.angle -= 90.0

    read(clock).second.angle = float<-((second_value % 60) * 6.0)
    read(clock).second.angle -= 90.0


function draw_clock_analog(clock: Clock, position: rl.Vector2) -> void:
    rl.draw_circle_v(position, float<-clock.second.length + 40.0, rl.LIGHTGRAY)
    rl.draw_circle_v(position, 12.0, rl.GRAY)

    var index = 0
    while index < 60:
        let long_tick = index % 5 == 0
        var outer_radius: float = float<-clock.second.length
        var line_thickness: float = 1.0
        if long_tick:
            outer_radius = float<-(outer_radius + 6.0)
            line_thickness = 3.0
        else:
            outer_radius = float<-(outer_radius + 10.0)
        let inner_radius = float<-clock.second.length + 20.0
        let angle = float<-(6.0 * float<-index - 90.0)
        rl.draw_line_ex(
            rl.Vector2(
                x = float<-(position.x + outer_radius * float<-math.cos(double<-(angle * DEG_TO_RAD))),
                y = float<-(position.y + outer_radius * float<-math.sin(double<-(angle * DEG_TO_RAD)))
            ),
            rl.Vector2(
                x = float<-(position.x + inner_radius * float<-math.cos(double<-(angle * DEG_TO_RAD))),
                y = float<-(position.y + inner_radius * float<-math.sin(double<-(angle * DEG_TO_RAD)))
            ),
            line_thickness,
            rl.DARKGRAY
        )
        index += 1

    rl.draw_rectangle_pro(
        rl.Rectangle(
            x = position.x,
            y = position.y,
            width = float<-clock.second.length,
            height = float<-clock.second.thickness
        ),
        rl.Vector2(x = 0.0, y = float<-clock.second.thickness / 2.0),
        clock.second.angle,
        clock.second.color
    )
    rl.draw_rectangle_pro(
        rl.Rectangle(
            x = position.x,
            y = position.y,
            width = float<-clock.minute.length,
            height = float<-clock.minute.thickness
        ),
        rl.Vector2(x = 0.0, y = float<-clock.minute.thickness / 2.0),
        clock.minute.angle,
        clock.minute.color
    )
    rl.draw_rectangle_pro(
        rl.Rectangle(
            x = position.x,
            y = position.y,
            width = float<-clock.hour.length,
            height = float<-clock.hour.thickness
        ),
        rl.Vector2(x = 0.0, y = float<-clock.hour.thickness / 2.0),
        clock.hour.angle,
        clock.hour.color
    )


function draw_clock_digital(clock: Clock, position: rl.Vector2) -> void:
    let off = rl.fade(rl.LIGHTGRAY, 0.3)
    let separator_color = blinking_separator_color(clock.second.value, rl.RED, off)

    draw_display_value(rl.Vector2(x = position.x, y = position.y), clock.hour.value / 10, rl.RED, off)
    draw_display_value(rl.Vector2(x = position.x + 120.0, y = position.y), clock.hour.value % 10, rl.RED, off)
    rl.draw_circle(int<-position.x + 240, int<-position.y + 70, 12.0, separator_color)
    rl.draw_circle(int<-position.x + 240, int<-position.y + 150, 12.0, separator_color)
    draw_display_value(rl.Vector2(x = position.x + 260.0, y = position.y), clock.minute.value / 10, rl.RED, off)
    draw_display_value(rl.Vector2(x = position.x + 380.0, y = position.y), clock.minute.value % 10, rl.RED, off)
    rl.draw_circle(int<-position.x + 500, int<-position.y + 70, 12.0, separator_color)
    rl.draw_circle(int<-position.x + 500, int<-position.y + 150, 12.0, separator_color)
    draw_display_value(rl.Vector2(x = position.x + 520.0, y = position.y), clock.second.value / 10, rl.RED, off)
    draw_display_value(rl.Vector2(x = position.x + 640.0, y = position.y), clock.second.value % 10, rl.RED, off)


function draw_display_value(position: rl.Vector2, value: int, color_on: rl.Color, color_off: rl.Color) -> void:
    if value == 0:
        draw_7s_display(position, 0b00111111, color_on, color_off)
    else if value == 1:
        draw_7s_display(position, 0b00000110, color_on, color_off)
    else if value == 2:
        draw_7s_display(position, 0b01011011, color_on, color_off)
    else if value == 3:
        draw_7s_display(position, 0b01001111, color_on, color_off)
    else if value == 4:
        draw_7s_display(position, 0b01100110, color_on, color_off)
    else if value == 5:
        draw_7s_display(position, 0b01101101, color_on, color_off)
    else if value == 6:
        draw_7s_display(position, 0b01111101, color_on, color_off)
    else if value == 7:
        draw_7s_display(position, 0b00000111, color_on, color_off)
    else if value == 8:
        draw_7s_display(position, 0b01111111, color_on, color_off)
    else if value == 9:
        draw_7s_display(position, 0b01101111, color_on, color_off)


function draw_7s_display(position: rl.Vector2, segments: int, color_on: rl.Color, color_off: rl.Color) -> void:
    let segment_len = 60
    let segment_thick = 20
    let offset_y_adjust: float = float<-segment_thick * 0.3

    draw_display_segment(
        rl.Vector2(
            x = position.x + float<-segment_thick + float<-segment_len / 2.0,
            y = position.y + float<-segment_thick
        ),
        segment_len,
        segment_thick,
        false,
        segment_color(segments, 0b00000001, color_on, color_off)
    )
    draw_display_segment(
        rl.Vector2(
            x = position.x + float<-segment_thick + float<-segment_len + float<-segment_thick / 2.0,
            y = position.y + 2.0 * float<-segment_thick + float<-segment_len / 2.0 - offset_y_adjust
        ),
        segment_len,
        segment_thick,
        true,
        segment_color(segments, 0b00000010, color_on, color_off)
    )
    draw_display_segment(
        rl.Vector2(
            x = position.x + float<-segment_thick + float<-segment_len + float<-segment_thick / 2.0,
            y = position.y + 4.0 * float<-segment_thick + float<-segment_len + float<-segment_len / 2.0 - 3.0 * offset_y_adjust
        ),
        segment_len,
        segment_thick,
        true,
        segment_color(segments, 0b00000100, color_on, color_off)
    )
    draw_display_segment(
        rl.Vector2(
            x = position.x + float<-segment_thick + float<-segment_len / 2.0,
            y = position.y + 5.0 * float<-segment_thick + 2.0 * float<-segment_len - 4.0 * offset_y_adjust
        ),
        segment_len,
        segment_thick,
        false,
        segment_color(segments, 0b00001000, color_on, color_off)
    )
    draw_display_segment(
        rl.Vector2(
            x = position.x + float<-segment_thick / 2.0,
            y = position.y + 4.0 * float<-segment_thick + float<-segment_len + float<-segment_len / 2.0 - 3.0 * offset_y_adjust
        ),
        segment_len,
        segment_thick,
        true,
        segment_color(segments, 0b00010000, color_on, color_off)
    )
    draw_display_segment(
        rl.Vector2(
            x = position.x + float<-segment_thick / 2.0,
            y = position.y + 2.0 * float<-segment_thick + float<-segment_len / 2.0 - offset_y_adjust
        ),
        segment_len,
        segment_thick,
        true,
        segment_color(segments, 0b00100000, color_on, color_off)
    )
    draw_display_segment(
        rl.Vector2(
            x = position.x + float<-segment_thick + float<-segment_len / 2.0,
            y = position.y + 3.0 * float<-segment_thick + float<-segment_len - 2.0 * offset_y_adjust
        ),
        segment_len,
        segment_thick,
        false,
        segment_color(segments, 0b01000000, color_on, color_off)
    )


function draw_display_segment(center: rl.Vector2, length: int, thick: int, vertical: bool, color: rl.Color) -> void:
    var points: array[rl.Vector2, 6] = zero[array[rl.Vector2, 6]]

    if not vertical:
        points[0] = rl.Vector2(x = center.x - float<-length / 2.0 - float<-thick / 2.0, y = center.y)
        points[1] = rl.Vector2(x = center.x - float<-length / 2.0, y = center.y + float<-thick / 2.0)
        points[2] = rl.Vector2(x = center.x - float<-length / 2.0, y = center.y - float<-thick / 2.0)
        points[3] = rl.Vector2(x = center.x + float<-length / 2.0, y = center.y + float<-thick / 2.0)
        points[4] = rl.Vector2(x = center.x + float<-length / 2.0, y = center.y - float<-thick / 2.0)
        points[5] = rl.Vector2(x = center.x + float<-length / 2.0 + float<-thick / 2.0, y = center.y)
    else:
        points[0] = rl.Vector2(x = center.x, y = center.y - float<-length / 2.0 - float<-thick / 2.0)
        points[1] = rl.Vector2(x = center.x - float<-thick / 2.0, y = center.y - float<-length / 2.0)
        points[2] = rl.Vector2(x = center.x + float<-thick / 2.0, y = center.y - float<-length / 2.0)
        points[3] = rl.Vector2(x = center.x - float<-thick / 2.0, y = center.y + float<-length / 2.0)
        points[4] = rl.Vector2(x = center.x + float<-thick / 2.0, y = center.y + float<-length / 2.0)
        points[5] = rl.Vector2(x = center.x, y = center.y + float<-length / 2.0 + float<-thick / 2.0)

    rl.draw_triangle_strip_ptr(ptr_of(points[0]), 6, color)


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - digital clock")
    defer rl.close_window()

    var clock_mode = CLOCK_DIGITAL
    var clock = Clock(
        second = ClockHand(value = 0, angle = 45.0, length = 140, thickness = 3, color = rl.MAROON),
        minute = ClockHand(value = 0, angle = 10.0, length = 130, thickness = 7, color = rl.DARKGRAY),
        hour = ClockHand(value = 0, angle = 0.0, length = 100, thickness = 7, color = rl.BLACK)
    )

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            if clock_mode == CLOCK_DIGITAL:
                clock_mode = CLOCK_ANALOG
            else:
                clock_mode = CLOCK_DIGITAL

        update_clock(ref_of(clock))

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        if clock_mode == CLOCK_ANALOG:
            draw_clock_analog(clock, rl.Vector2(x = 400.0, y = 240.0))
        else:
            draw_clock_digital(clock, rl.Vector2(x = 30.0, y = 60.0))
            let clock_time = text.cstr_as_str(rl.text_format(
                "%02i:%02i:%02i",
                clock.hour.value,
                clock.minute.value,
                clock.second.value
            ))
            rl.draw_text(
                clock_time,
                rl.get_screen_width() / 2 - rl.measure_text(clock_time, 150) / 2,
                300,
                150,
                rl.BLACK
            )

        var mode_name = "ANALOGUE CLOCK"
        if clock_mode == CLOCK_DIGITAL:
            mode_name = "DIGITAL CLOCK"
        rl.draw_text(
            text.cstr_as_str(rl.text_format("Press [SPACE] to switch clock mode: %s", mode_name)),
            10,
            10,
            20,
            rl.DARKGRAY
        )
        rl.end_drawing()

    return 0
