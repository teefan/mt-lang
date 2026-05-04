module examples.idiomatic.raylib.clock_of_clocks

import std.raylib as rl
import std.raylib.math as math
import std.time as time

const screen_width: i32 = 800
const screen_height: i32 = 450
const digit_count: i32 = 6
const cells_per_digit: i32 = 24
const total_cells: i32 = 144
const hour_mode_24: i32 = 24
const hour_mode_12: i32 = 12
const hands_move_duration: f32 = 0.5


def blank_digit_angles() -> array[rl.Vector2, 24]:
    let zz = rl.Vector2(x = 135.0, y = 135.0)
    var result = zero[array[rl.Vector2, 24]]()
    for index in 0..cells_per_digit:
        result[index] = zz
    return result


def digit_angles_for(digit: i32) -> array[rl.Vector2, 24]:
    let tl = rl.Vector2(x = 0.0, y = 90.0)
    let tr = rl.Vector2(x = 90.0, y = 180.0)
    let br = rl.Vector2(x = 180.0, y = 270.0)
    let bl = rl.Vector2(x = 0.0, y = 270.0)
    let hh = rl.Vector2(x = 0.0, y = 180.0)
    let vv = rl.Vector2(x = 90.0, y = 270.0)
    let zz = rl.Vector2(x = 135.0, y = 135.0)

    if digit == 0:
        return array[rl.Vector2, 24](
            tl, hh, hh, tr,
            vv, tl, tr, vv,
            vv, vv, vv, vv,
            vv, vv, vv, vv,
            vv, bl, br, vv,
            bl, hh, hh, br,
        )
    elif digit == 1:
        return array[rl.Vector2, 24](
            tl, hh, tr, zz,
            bl, tr, vv, zz,
            zz, vv, vv, zz,
            zz, vv, vv, zz,
            tl, br, bl, tr,
            bl, hh, hh, br,
        )
    elif digit == 2:
        return array[rl.Vector2, 24](
            tl, hh, hh, tr,
            bl, hh, tr, vv,
            tl, hh, br, vv,
            vv, tl, hh, br,
            vv, bl, hh, tr,
            bl, hh, hh, br,
        )
    elif digit == 3:
        return array[rl.Vector2, 24](
            tl, hh, hh, tr,
            bl, hh, tr, vv,
            tl, hh, br, vv,
            bl, hh, tr, vv,
            tl, hh, br, vv,
            bl, hh, hh, br,
        )
    elif digit == 4:
        return array[rl.Vector2, 24](
            tl, tr, tl, tr,
            vv, vv, vv, vv,
            vv, bl, br, vv,
            bl, hh, tr, vv,
            zz, zz, vv, vv,
            zz, zz, bl, br,
        )
    elif digit == 5:
        return array[rl.Vector2, 24](
            tl, hh, hh, tr,
            vv, tl, hh, br,
            vv, bl, hh, tr,
            bl, hh, tr, vv,
            tl, hh, br, vv,
            bl, hh, hh, br,
        )
    elif digit == 6:
        return array[rl.Vector2, 24](
            tl, hh, hh, tr,
            vv, tl, hh, br,
            vv, bl, hh, tr,
            vv, tl, tr, vv,
            vv, bl, br, vv,
            bl, hh, hh, br,
        )
    elif digit == 7:
        return array[rl.Vector2, 24](
            tl, hh, hh, tr,
            bl, hh, tr, vv,
            zz, zz, vv, vv,
            zz, zz, vv, vv,
            zz, zz, vv, vv,
            zz, zz, bl, br,
        )
    elif digit == 8:
        return array[rl.Vector2, 24](
            tl, hh, hh, tr,
            vv, tl, tr, vv,
            vv, bl, br, vv,
            vv, tl, tr, vv,
            vv, bl, br, vv,
            bl, hh, hh, br,
        )
    elif digit == 9:
        return array[rl.Vector2, 24](
            tl, hh, hh, tr,
            vv, tl, tr, vv,
            vv, bl, br, vv,
            bl, hh, tr, vv,
            tl, hh, br, vv,
            bl, hh, hh, br,
        )

    return blank_digit_angles()


def digits_for(clock: time.ClockTime, hour_mode: i32) -> array[i32, 6]:
    var result = zero[array[i32, 6]]()
    let hour_value = if hour_mode == hour_mode_24: clock.hour else: time.hour_12(clock)
    result[0] = hour_value / 10
    result[1] = hour_value % 10
    result[2] = clock.minute / 10
    result[3] = clock.minute % 10
    result[4] = clock.second / 10
    result[5] = clock.second % 10
    return result


def angle_slot(digit: i32, cell: i32) -> i32:
    return digit * cells_per_digit + cell


def refresh_digits(current_clock: time.ClockTime, hour_mode: i32, current_angles: array[rl.Vector2, 144], src_angles: ref[array[rl.Vector2, 144]], dst_angles: ref[array[rl.Vector2, 144]]) -> void:
    let display_digits = digits_for(current_clock, hour_mode)
    let blank_leading_hour = hour_mode == hour_mode_12 and time.hour_12(current_clock) < 10

    for digit in 0..digit_count:
        let digit_angles = if digit == 0 and blank_leading_hour: blank_digit_angles() else: digit_angles_for(display_digits[digit])

        for cell in 0..cells_per_digit:
            let slot = angle_slot(digit, cell)
            let target_angle = digit_angles[cell]
            read(src_angles)[slot] = current_angles[slot]
            read(dst_angles)[slot] = target_angle

            if read(src_angles)[slot].x > target_angle.x:
                read(src_angles)[slot].x -= 360.0
            if read(src_angles)[slot].y > target_angle.y:
                read(src_angles)[slot].y -= 360.0


def main() -> i32:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(screen_width, screen_height, "Milk Tea Clock of Clocks")
    defer rl.close_window()

    let bg_color = rl.color_lerp(rl.DARKBLUE, rl.BLACK, 0.75)
    let hands_color = rl.color_lerp(rl.YELLOW, rl.RAYWHITE, 0.25)

    let clock_face_size: f32 = 24.0
    let clock_face_spacing: f32 = 8.0
    let section_spacing: f32 = 16.0

    var previous_second = -1
    var previous_hour_mode = -1
    var current_angles = zero[array[rl.Vector2, 144]]()
    var src_angles = zero[array[rl.Vector2, 144]]()
    var dst_angles = zero[array[rl.Vector2, 144]]()
    var hands_move_timer: f32 = 0.0
    var hour_mode = hour_mode_24
    var current_clock = time.ClockTime(hour = 0, minute = 0, second = 0)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            if hour_mode == hour_mode_24:
                hour_mode = hour_mode_12
            else:
                hour_mode = hour_mode_24

        let loaded_clock = time.local_clock()
        if loaded_clock.is_ok:
            current_clock = loaded_clock.value

        if current_clock.second != previous_second or hour_mode != previous_hour_mode:
            previous_second = current_clock.second
            previous_hour_mode = hour_mode
            refresh_digits(current_clock, hour_mode, current_angles, ref_of(src_angles), ref_of(dst_angles))
            hands_move_timer = -rl.get_frame_time()

        if hands_move_timer < hands_move_duration:
            hands_move_timer = math.clamp(hands_move_timer + rl.get_frame_time(), 0.0, hands_move_duration)
            let t = hands_move_timer / hands_move_duration
            let smooth_t = t * t * (3.0 - 2.0 * t)

            for digit in 0..digit_count:
                for cell in 0..cells_per_digit:
                    let slot = angle_slot(digit, cell)
                    current_angles[slot].x = math.lerp(src_angles[slot].x, dst_angles[slot].x, smooth_t)
                    current_angles[slot].y = math.lerp(src_angles[slot].y, dst_angles[slot].y, smooth_t)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(bg_color)
        rl.draw_text(rl.text_format_i32("%d-h mode, space to change", hour_mode), 10, 30, 20, rl.RAYWHITE)

        var x_offset: f32 = 4.0
        for digit in 0..digit_count:
            for row in 0..6:
                for col in 0..4:
                    let center = rl.Vector2(
                        x = x_offset + f32<-col * (clock_face_size + clock_face_spacing) + clock_face_size * 0.5,
                        y = 100.0 + f32<-row * (clock_face_size + clock_face_spacing) + clock_face_size * 0.5,
                    )
                    let slot = angle_slot(digit, row * 4 + col)

                    rl.draw_ring(center, clock_face_size * 0.5 - 2.0, clock_face_size * 0.5, 0.0, 360.0, 24, rl.DARKGRAY)

                    rl.draw_rectangle_pro(
                        rl.Rectangle(x = center.x, y = center.y, width = clock_face_size * 0.5 + 4.0, height = 4.0),
                        rl.Vector2(x = 2.0, y = 2.0),
                        current_angles[slot].x,
                        hands_color,
                    )
                    rl.draw_rectangle_pro(
                        rl.Rectangle(x = center.x, y = center.y, width = clock_face_size * 0.5 + 2.0, height = 4.0),
                        rl.Vector2(x = 2.0, y = 2.0),
                        current_angles[slot].y,
                        hands_color,
                    )

            x_offset += (clock_face_size + clock_face_spacing) * 4.0
            if digit == 1 or digit == 3:
                rl.draw_ring(rl.Vector2(x = x_offset + 4.0, y = 160.0), 6.0, 8.0, 0.0, 360.0, 24, hands_color)
                rl.draw_ring(rl.Vector2(x = x_offset + 4.0, y = 225.0), 6.0, 8.0, 0.0, 360.0, 24, hands_color)
                x_offset += section_spacing

        rl.draw_fps(10, 10)

    return 0
