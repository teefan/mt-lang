import std.raylib as rl
import std.raymath as rm
import std.str as text
import std.time as time

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const CLOCK_DIGITS: int = 6
const CLOCK_CELLS: int = 24
const HANDS_MOVE_DURATION: float = 0.5


function parse_ascii_digit(value: ubyte) -> int:
    return int<-(value - ubyte<-48)


function parse_two_digits(value_text: str, offset: ptr_uint) -> int:
    return parse_ascii_digit(value_text.byte_at(offset)) * 10 + parse_ascii_digit(value_text.byte_at(offset + ptr_uint<-1))


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shapes] example - clock of clocks")
    defer rl.close_window()

    let bg_color = rl.color_lerp(rl.DARKBLUE, rl.BLACK, 0.75)
    let hands_color = rl.color_lerp(rl.YELLOW, rl.RAYWHITE, 0.25)

    let clock_face_size: float = 24.0
    let clock_face_spacing: float = 8.0
    let section_spacing: float = 16.0

    let TL = rl.Vector2(x = 0.0, y = 90.0)
    let TR = rl.Vector2(x = 90.0, y = 180.0)
    let BR = rl.Vector2(x = 180.0, y = 270.0)
    let BL = rl.Vector2(x = 0.0, y = 270.0)
    let HH = rl.Vector2(x = 0.0, y = 180.0)
    let VV = rl.Vector2(x = 90.0, y = 270.0)
    let ZZ = rl.Vector2(x = 135.0, y = 135.0)

    let digit_angles = array[array[rl.Vector2, CLOCK_CELLS], 10](
        array[rl.Vector2, CLOCK_CELLS](
            TL,
            HH,
            HH,
            TR,
            VV,
            TL,
            TR,
            VV,
            VV,
            VV,
            VV,
            VV,
            VV,
            VV,
            VV,
            VV,
            VV,
            BL,
            BR,
            VV,
            BL,
            HH,
            HH,
            BR
        ),
        array[rl.Vector2, CLOCK_CELLS](
            TL,
            HH,
            TR,
            ZZ,
            BL,
            TR,
            VV,
            ZZ,
            ZZ,
            VV,
            VV,
            ZZ,
            ZZ,
            VV,
            VV,
            ZZ,
            TL,
            BR,
            BL,
            TR,
            BL,
            HH,
            HH,
            BR
        ),
        array[rl.Vector2, CLOCK_CELLS](
            TL,
            HH,
            HH,
            TR,
            BL,
            HH,
            TR,
            VV,
            TL,
            HH,
            BR,
            VV,
            VV,
            TL,
            HH,
            BR,
            VV,
            BL,
            HH,
            TR,
            BL,
            HH,
            HH,
            BR
        ),
        array[rl.Vector2, CLOCK_CELLS](
            TL,
            HH,
            HH,
            TR,
            BL,
            HH,
            TR,
            VV,
            TL,
            HH,
            BR,
            VV,
            BL,
            HH,
            TR,
            VV,
            TL,
            HH,
            BR,
            VV,
            BL,
            HH,
            HH,
            BR
        ),
        array[rl.Vector2, CLOCK_CELLS](
            TL,
            TR,
            TL,
            TR,
            VV,
            VV,
            VV,
            VV,
            VV,
            BL,
            BR,
            VV,
            BL,
            HH,
            TR,
            VV,
            ZZ,
            ZZ,
            VV,
            VV,
            ZZ,
            ZZ,
            BL,
            BR
        ),
        array[rl.Vector2, CLOCK_CELLS](
            TL,
            HH,
            HH,
            TR,
            VV,
            TL,
            HH,
            BR,
            VV,
            BL,
            HH,
            TR,
            BL,
            HH,
            TR,
            VV,
            TL,
            HH,
            BR,
            VV,
            BL,
            HH,
            HH,
            BR
        ),
        array[rl.Vector2, CLOCK_CELLS](
            TL,
            HH,
            HH,
            TR,
            VV,
            TL,
            HH,
            BR,
            VV,
            BL,
            HH,
            TR,
            VV,
            TL,
            TR,
            VV,
            VV,
            BL,
            BR,
            VV,
            BL,
            HH,
            HH,
            BR
        ),
        array[rl.Vector2, CLOCK_CELLS](
            TL,
            HH,
            HH,
            TR,
            BL,
            HH,
            TR,
            VV,
            ZZ,
            ZZ,
            VV,
            VV,
            ZZ,
            ZZ,
            VV,
            VV,
            ZZ,
            ZZ,
            VV,
            VV,
            ZZ,
            ZZ,
            BL,
            BR
        ),
        array[rl.Vector2, CLOCK_CELLS](
            TL,
            HH,
            HH,
            TR,
            VV,
            TL,
            TR,
            VV,
            VV,
            BL,
            BR,
            VV,
            VV,
            TL,
            TR,
            VV,
            VV,
            BL,
            BR,
            VV,
            BL,
            HH,
            HH,
            BR
        ),
        array[rl.Vector2, CLOCK_CELLS](
            TL,
            HH,
            HH,
            TR,
            VV,
            TL,
            TR,
            VV,
            VV,
            BL,
            BR,
            VV,
            BL,
            HH,
            TR,
            VV,
            TL,
            HH,
            BR,
            VV,
            BL,
            HH,
            HH,
            BR
        )
    )

    var prev_seconds = -1
    var current_angles: array[
        array[rl.Vector2, CLOCK_CELLS],
        CLOCK_DIGITS
    ] = zero[array[array[rl.Vector2, CLOCK_CELLS], CLOCK_DIGITS]]
    var src_angles: array[
        array[rl.Vector2, CLOCK_CELLS],
        CLOCK_DIGITS
    ] = zero[array[array[rl.Vector2, CLOCK_CELLS], CLOCK_DIGITS]]
    var dst_angles: array[
        array[rl.Vector2, CLOCK_CELLS],
        CLOCK_DIGITS
    ] = zero[array[array[rl.Vector2, CLOCK_CELLS], CLOCK_DIGITS]]
    var hands_move_timer: float = 0.0
    var hour_mode = 24

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let now = time.now()
        var time_buffer = zero[array[char, 7]]
        if time.format_local_time_into(ptr_of(time_buffer[0]), ptr_uint<-7, "%H%M%S", now) != 0:
            let clock_text = text.chars_as_str(ptr_of(time_buffer[0]))
            let seconds = parse_two_digits(clock_text, ptr_uint<-4)
            if seconds != prev_seconds:
                prev_seconds = seconds

                let hour_value = parse_two_digits(clock_text, ptr_uint<-0) % hour_mode
                let digit_values = array[int, CLOCK_DIGITS](
                    hour_value / 10,
                    hour_value % 10,
                    parse_two_digits(clock_text, ptr_uint<-2) / 10,
                    parse_two_digits(clock_text, ptr_uint<-2) % 10,
                    seconds / 10,
                    seconds % 10
                )
                let leading_blank = hour_mode == 12 and digit_values[0] == 0

                var digit = 0
                while digit < CLOCK_DIGITS:
                    var cell = 0
                    while cell < CLOCK_CELLS:
                        src_angles[digit][cell] = current_angles[digit][cell]
                        let digit_index = digit_values[digit]
                        dst_angles[digit][cell] = digit_angles[digit_index][cell]

                        if digit == 0 and leading_blank:
                            dst_angles[digit][cell] = ZZ
                        if src_angles[digit][cell].x > dst_angles[digit][cell].x:
                            src_angles[digit][cell].x -= 360.0
                        if src_angles[digit][cell].y > dst_angles[digit][cell].y:
                            src_angles[digit][cell].y -= 360.0
                        cell += 1
                    digit += 1

                hands_move_timer = -rl.get_frame_time()

        if hands_move_timer < HANDS_MOVE_DURATION:
            hands_move_timer = rm.clamp(hands_move_timer + rl.get_frame_time(), 0.0, HANDS_MOVE_DURATION)

            var t = hands_move_timer / HANDS_MOVE_DURATION
            t = t * t * (3.0 - 2.0 * t)

            var digit = 0
            while digit < CLOCK_DIGITS:
                var cell = 0
                while cell < CLOCK_CELLS:
                    current_angles[digit][cell].x = rm.lerp(src_angles[digit][cell].x, dst_angles[digit][cell].x, t)
                    current_angles[digit][cell].y = rm.lerp(src_angles[digit][cell].y, dst_angles[digit][cell].y, t)
                    cell += 1
                digit += 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            hour_mode = 36 - hour_mode

        rl.begin_drawing()
        rl.clear_background(bg_color)

        rl.draw_text(text.cstr_as_str(rl.text_format("%d-h mode, space to change", hour_mode)), 10, 30, 20, rl.RAYWHITE)

        var x_offset: float = 4.0
        var digit = 0
        while digit < CLOCK_DIGITS:
            var row = 0
            while row < 6:
                var col = 0
                while col < 4:
                    let centre = rl.Vector2(
                        x = x_offset + float<-col * (clock_face_size + clock_face_spacing) + clock_face_size * 0.5,
                        y = 100.0 + float<-row * (clock_face_size + clock_face_spacing) + clock_face_size * 0.5
                    )

                    rl.draw_ring(
                        centre,
                        clock_face_size * 0.5 - 2.0,
                        clock_face_size * 0.5,
                        0.0,
                        360.0,
                        24,
                        rl.DARKGRAY
                    )

                    rl.draw_rectangle_pro(
                        rl.Rectangle(x = centre.x, y = centre.y, width = clock_face_size * 0.5 + 4.0, height = 4.0),
                        rl.Vector2(x = 2.0, y = 2.0),
                        current_angles[digit][row * 4 + col].x,
                        hands_color
                    )
                    rl.draw_rectangle_pro(
                        rl.Rectangle(x = centre.x, y = centre.y, width = clock_face_size * 0.5 + 2.0, height = 4.0),
                        rl.Vector2(x = 2.0, y = 2.0),
                        current_angles[digit][row * 4 + col].y,
                        hands_color
                    )
                    col += 1
                row += 1

            x_offset += (clock_face_size + clock_face_spacing) * 4.0
            if digit % 2 == 1:
                rl.draw_ring(rl.Vector2(x = x_offset + 4.0, y = 160.0), 6.0, 8.0, 0.0, 360.0, 24, hands_color)
                rl.draw_ring(rl.Vector2(x = x_offset + 4.0, y = 225.0), 6.0, 8.0, 0.0, 360.0, 24, hands_color)
                x_offset += section_spacing
            digit += 1

        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
