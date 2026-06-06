import std.c.terminal as c
import std.fmt as fmt
import std.string as string
import std.vec as vec

public struct Size:
    width: int
    height: int

public struct Error:
    code: int
    message: string.String

public enum Color: int
    black = 0
    red = 1
    green = 2
    yellow = 3
    blue = 4
    magenta = 5
    cyan = 6
    white = 7
    bright_black = 8
    bright_red = 9
    bright_green = 10
    bright_yellow = 11
    bright_blue = 12
    bright_magenta = 13
    bright_cyan = 14
    bright_white = 15

public enum KeyCode: int
    none = 0
    character = 1
    enter = 2
    escape = 3
    backspace = 4
    tab = 5
    shift_tab = 6
    up = 7
    down = 8
    left = 9
    right = 10
    home = 11
    end = 12
    page_up = 13
    page_down = 14
    insert = 15
    delete = 16
    function_1 = 17
    function_2 = 18
    function_3 = 19
    function_4 = 20
    unknown = 21

public enum MouseAction: int
    none = 0
    press = 1
    release = 2
    move = 3
    scroll_up = 4
    scroll_down = 5

public enum MouseButton: int
    none = 0
    left = 1
    middle = 2
    right = 3

public enum EventKind: int
    none = 0
    key = 1
    mouse = 2
    resize = 3

public struct KeyEvent:
    code: KeyCode
    input_byte: ubyte
    has_byte: bool
    ctrl: bool
    alt: bool
    shifted: bool

public struct MouseEvent:
    action: MouseAction
    button: MouseButton
    column: int
    row: int
    ctrl: bool
    alt: bool
    shifted: bool

public struct Event:
    kind: EventKind
    key: KeyEvent
    mouse: MouseEvent
    size: Size

struct ParsedDecimal:
    value: int
    next_index: ptr_uint

public struct Terminal:
    input: vec.Vec[ubyte]
    size: Size
    raw_mode: bool
    alternate_screen: bool
    cursor_hidden: bool
    mouse_enabled: bool


function take_owned_string(data: ptr[char]?, len: ptr_uint) -> string.String:
    if data == null:
        if len != 0:
            fatal(c"terminal.take_owned_string missing storage")

        return string.String.create()

    return unsafe: string.String(data = ptr[ubyte]<-data, len = len, capacity = len, owns_storage = true)


function take_error(raw: c.mt_terminal_error, fallback: str) -> Error:
    if raw.message_data == null and raw.message_len == 0:
        return Error(code = raw.code, message = string.String.from_str(fallback))

    return Error(code = raw.code, message = take_owned_string(raw.message_data, raw.message_len))


function default_key_event() -> KeyEvent:
    return KeyEvent(code = KeyCode.none, input_byte = 0, has_byte = false, ctrl = false, alt = false, shifted = false)


function default_mouse_event() -> MouseEvent:
    return MouseEvent(
        action = MouseAction.none,
        button = MouseButton.none,
        column = 0,
        row = 0,
        ctrl = false,
        alt = false,
        shifted = false
    )


function key_event(code: KeyCode, input_value: ubyte, has_byte: bool, ctrl: bool, alt: bool, shifted: bool) -> Event:
    return Event(
        kind = EventKind.key,
        key = KeyEvent(
            code = code,
            input_byte = input_value,
            has_byte = has_byte,
            ctrl = ctrl,
            alt = alt,
            shifted = shifted
        ),
        mouse = default_mouse_event(),
        size = Size(width = 0, height = 0)
    )


function mouse_event(
    action: MouseAction,
    button: MouseButton,
    column: int,
    row: int,
    ctrl: bool,
    alt: bool,
    shifted: bool
) -> Event:
    return Event(
        kind = EventKind.mouse,
        key = default_key_event(),
        mouse = MouseEvent(
            action = action,
            button = button,
            column = column,
            row = row,
            ctrl = ctrl,
            alt = alt,
            shifted = shifted
        ),
        size = Size(width = 0, height = 0)
    )


function resize_event(current: Size) -> Event:
    return Event(kind = EventKind.resize, key = default_key_event(), mouse = default_mouse_event(), size = current)


function clamp_cursor_position(value: int) -> int:
    if value < 1:
        return 1

    return value


function clamp_color_channel(value: int) -> int:
    if value < 0:
        return 0
    if value > 255:
        return 255

    return value


function append_escape(output: ref[string.String]) -> void:
    output.push_byte(27)


function append_csi(output: ref[string.String], suffix: str) -> void:
    append_escape(output)
    output.append("[")
    output.append(suffix)


function write_stdout_bytes(data: const_ptr[ubyte]?, len: ptr_uint, fallback: str) -> Result[ptr_uint, Error]:
    var written: ptr_uint = 0
    var raw_error = zero[c.mt_terminal_error]
    let status = c.mt_terminal_write_stdout(data, len, written, raw_error)
    if status != 0:
        return Result[ptr_uint, Error].failure(error= take_error(raw_error, fallback))

    return Result[ptr_uint, Error].success(value= written)


function write_stderr_bytes(data: const_ptr[ubyte]?, len: ptr_uint, fallback: str) -> Result[ptr_uint, Error]:
    var written: ptr_uint = 0
    var raw_error = zero[c.mt_terminal_error]
    let status = c.mt_terminal_write_stderr(data, len, written, raw_error)
    if status != 0:
        return Result[ptr_uint, Error].failure(error= take_error(raw_error, fallback))

    return Result[ptr_uint, Error].success(value= written)


function write_stdout_sequence(sequence: string.String, fallback: str) -> Result[bool, Error]:
    var data: const_ptr[ubyte]? = null
    if sequence.len != 0:
        data = unsafe: const_ptr[ubyte]<-sequence.data

    match write_stdout_bytes(data, sequence.len, fallback):
        Result.failure as payload:
            return Result[bool, Error].failure(error= payload.error)
        Result.success:
            return Result[bool, Error].success(value= true)


function flush_stdout_internal() -> Result[bool, Error]:
    var raw_error = zero[c.mt_terminal_error]
    let status = c.mt_terminal_flush_stdout(raw_error)
    if status != 0:
        return Result[bool, Error].failure(error= take_error(raw_error, "terminal flush failed"))

    return Result[bool, Error].success(value= true)


function flush_stderr_internal() -> Result[bool, Error]:
    var raw_error = zero[c.mt_terminal_error]
    let status = c.mt_terminal_flush_stderr(raw_error)
    if status != 0:
        return Result[bool, Error].failure(error= take_error(raw_error, "terminal flush failed"))

    return Result[bool, Error].success(value= true)


function raw_mode_enter() -> Result[bool, Error]:
    var raw_error = zero[c.mt_terminal_error]
    let status = c.mt_terminal_enter_raw_mode(raw_error)
    if status != 0:
        return Result[bool, Error].failure(error= take_error(raw_error, "terminal raw mode failed"))

    return Result[bool, Error].success(value= true)


function raw_mode_leave() -> Result[bool, Error]:
    var raw_error = zero[c.mt_terminal_error]
    let status = c.mt_terminal_leave_raw_mode(raw_error)
    if status != 0:
        return Result[bool, Error].failure(error= take_error(raw_error, "terminal raw mode restore failed"))

    return Result[bool, Error].success(value= true)


function read_stdin(timeout_ms: int) -> Result[vec.Vec[ubyte], Error]:
    var buffer = zero[array[ubyte, 128]]
    var read_count: ptr_uint = 0
    var raw_error = zero[c.mt_terminal_error]
    let status = c.mt_terminal_read_stdin(ptr_of(buffer[0]), 128, timeout_ms, read_count, raw_error)
    if status != 0:
        return Result[vec.Vec[ubyte], Error].failure(error= take_error(raw_error, "terminal read failed"))

    var result = vec.Vec[ubyte].with_capacity(read_count)
    if read_count != 0:
        unsafe:
            let read_span = span[ubyte](data = ptr[ubyte]<-ptr_of(buffer[0]), len = read_count)
            result.append_span(read_span)

    return Result[vec.Vec[ubyte], Error].success(value= result)


function get_size_internal() -> Result[Size, Error]:
    var raw_size = zero[c.mt_terminal_size]
    var raw_error = zero[c.mt_terminal_error]
    let status = c.mt_terminal_get_size(raw_size, raw_error)
    if status != 0:
        return Result[Size, Error].failure(error= take_error(raw_error, "terminal size query failed"))

    return Result[Size, Error].success(value= Size(width = raw_size.width, height = raw_size.height))


function append_color_code(output: ref[string.String], color: Color, background: bool) -> void:
    let code = int<-color
    var base = 30
    var bright_base = 90
    if background:
        base = 40
        bright_base = 100
    if code < 8:
        fmt.append_int(output, base + code)
        return

    fmt.append_int(output, bright_base + (code - 8))


function apply_modifier(key: ref[KeyEvent], modifier: int) -> void:
    if modifier <= 1:
        return

    let modifier_bits = modifier - 1
    unsafe:
        read(key).shifted = (modifier_bits & 1) != 0
        read(key).alt = (modifier_bits & 2) != 0
        read(key).ctrl = (modifier_bits & 4) != 0


function get_byte(buffer: vec.Vec[ubyte], index: ptr_uint) -> Option[ubyte]:
    let value = buffer.get(index) else:
        return Option[ubyte].none

    return Option[ubyte].some(value = unsafe: read(value))


function get_ref_byte(buffer: ref[vec.Vec[ubyte]], index: ptr_uint) -> Option[ubyte]:
    return get_byte(read(buffer), index)


function consume_bytes(buffer: ref[vec.Vec[ubyte]], count: ptr_uint) -> void:
    var remaining = count
    while remaining > 0 and not buffer.is_empty():
        match buffer.remove(0):
            Option.some:
                pass
            Option.none:
                break
        remaining -= 1


function parse_decimal(buffer: vec.Vec[ubyte], start: ptr_uint) -> Option[ParsedDecimal]:
    var value = 0
    var next_index = start

    var parsed = false
    while next_index < buffer.len():
        match get_byte(buffer, next_index):
            Option.some as payload:
                let current_byte = payload.value
                if current_byte < 48 or current_byte > 57:
                    break

                parsed = true
                value *= 10
                value += int<-(current_byte - 48)
                next_index += 1
            Option.none:
                break

    if not parsed:
        return Option[ParsedDecimal].none

    return Option[ParsedDecimal].some(value = ParsedDecimal(value = value, next_index = next_index))


function parse_simple_key(input_value: ubyte, alt: bool) -> Event:
    if input_value == 13 or input_value == 10:
        return key_event(KeyCode.enter, 0, false, false, alt, false)
    if input_value == 9:
        return key_event(KeyCode.tab, 0, false, false, alt, false)
    if input_value == 8 or input_value == 127:
        return key_event(KeyCode.backspace, 0, false, false, alt, false)
    if input_value == 27:
        return key_event(KeyCode.escape, 0, false, false, alt, false)
    if input_value < 32:
        if input_value >= 1 and input_value <= 26:
            let ascii_code = int<-input_value
            return key_event(KeyCode.character, ubyte<-(96 + ascii_code), true, true, alt, false)
        if input_value >= 28 and input_value <= 31:
            let ascii_code = int<-input_value
            return key_event(KeyCode.character, ubyte<-(64 + ascii_code), true, true, alt, false)
        return key_event(KeyCode.unknown, input_value, true, true, alt, false)

    return key_event(KeyCode.character, input_value, true, false, alt, false)


function parse_ss3_event(buffer: ref[vec.Vec[ubyte]]) -> Option[Event]:
    match get_ref_byte(buffer, 2):
        Option.some as payload:
            consume_bytes(buffer, 3)
            match payload.value:
                80:
                    return Option[Event].some(value = key_event(KeyCode.function_1, 0, false, false, false, false))
                81:
                    return Option[Event].some(value = key_event(KeyCode.function_2, 0, false, false, false, false))
                82:
                    return Option[Event].some(value = key_event(KeyCode.function_3, 0, false, false, false, false))
                83:
                    return Option[Event].some(value = key_event(KeyCode.function_4, 0, false, false, false, false))
                72:
                    return Option[Event].some(value = key_event(KeyCode.home, 0, false, false, false, false))
                70:
                    return Option[Event].some(value = key_event(KeyCode.end, 0, false, false, false, false))
                _:
                    return Option[Event].some(value = key_event(KeyCode.unknown, 0, false, false, false, false))
        Option.none:
            return Option[Event].none


function decode_mouse_button(code: int) -> MouseButton:
    match code & 3:
        0:
            return MouseButton.left
        1:
            return MouseButton.middle
        2:
            return MouseButton.right
        _:
            return MouseButton.none


function parse_mouse_event(buffer: ref[vec.Vec[ubyte]]) -> Option[Event]:
    let button_code_payload = parse_decimal(read(buffer), 3) else:
        return Option[Event].none

    let button_code = button_code_payload.value
    var next_index = button_code_payload.next_index

    match get_ref_byte(buffer, next_index):
        Option.some as separator_payload:
            if separator_payload.value != 59:
                consume_bytes(buffer, next_index + 1)
                return Option[Event].some(value = key_event(KeyCode.unknown, 0, false, false, false, false))
        Option.none:
            return Option[Event].none

    next_index += 1
    let column_payload = parse_decimal(read(buffer), next_index) else:
        return Option[Event].none

    let column = column_payload.value
    next_index = column_payload.next_index

    match get_ref_byte(buffer, next_index):
        Option.some as separator_payload:
            if separator_payload.value != 59:
                consume_bytes(buffer, next_index + 1)
                return Option[Event].some(value = key_event(KeyCode.unknown, 0, false, false, false, false))
        Option.none:
            return Option[Event].none

    next_index += 1
    let row_payload = parse_decimal(read(buffer), next_index) else:
        return Option[Event].none

    let row = row_payload.value
    next_index = row_payload.next_index

    match get_ref_byte(buffer, next_index):
        Option.some as payload:
            consume_bytes(buffer, next_index + 1)
            let final_byte = payload.value
            let shifted = (button_code & 4) != 0
            let alt = (button_code & 8) != 0
            let ctrl = (button_code & 16) != 0

            if (button_code & 64) != 0:
                if (button_code & 1) != 0:
                    return Option[Event].some(value = mouse_event(
                        MouseAction.scroll_down,
                        MouseButton.none,
                        column,
                        row,
                        ctrl,
                        alt,
                        shifted
                    ))
                return Option[Event].some(value = mouse_event(
                    MouseAction.scroll_up,
                    MouseButton.none,
                    column,
                    row,
                    ctrl,
                    alt,
                    shifted
                ))

            if final_byte == 109:
                return Option[Event].some(value = mouse_event(
                    MouseAction.release,
                    decode_mouse_button(button_code),
                    column,
                    row,
                    ctrl,
                    alt,
                    shifted
                ))

            if (button_code & 32) != 0:
                return Option[Event].some(value = mouse_event(
                    MouseAction.move,
                    decode_mouse_button(button_code),
                    column,
                    row,
                    ctrl,
                    alt,
                    shifted
                ))

            return Option[Event].some(value = mouse_event(
                MouseAction.press,
                decode_mouse_button(button_code),
                column,
                row,
                ctrl,
                alt,
                shifted
            ))
        Option.none:
            return Option[Event].none


function parse_csi_letter(buffer: ref[vec.Vec[ubyte]], final_byte: ubyte, modifier: int) -> Event:
    var event_ = key_event(KeyCode.unknown, 0, false, false, false, false)
    if final_byte == 65:
        event_ = key_event(KeyCode.up, 0, false, false, false, false)
    else if final_byte == 66:
        event_ = key_event(KeyCode.down, 0, false, false, false, false)
    else if final_byte == 67:
        event_ = key_event(KeyCode.right, 0, false, false, false, false)
    else if final_byte == 68:
        event_ = key_event(KeyCode.left, 0, false, false, false, false)
    else if final_byte == 72:
        event_ = key_event(KeyCode.home, 0, false, false, false, false)
    else if final_byte == 70:
        event_ = key_event(KeyCode.end, 0, false, false, false, false)
    else if final_byte == 90:
        event_ = key_event(KeyCode.shift_tab, 0, false, false, false, true)

    apply_modifier(ref_of(event_.key), modifier)
    return event_


function parse_csi_event(buffer: ref[vec.Vec[ubyte]]) -> Option[Event]:
    match get_ref_byte(buffer, 2):
        Option.some as payload:
            let first = payload.value
            if first == 65 or first == 66 or first == 67 or first == 68 or first == 72 or first == 70 or first == 90:
                consume_bytes(buffer, 3)
                return Option[Event].some(value = parse_csi_letter(buffer, first, 1))

            if first == 60:
                return parse_mouse_event(buffer)

            if first < 48 or first > 57:
                consume_bytes(buffer, 3)
                return Option[Event].some(value = key_event(KeyCode.unknown, 0, false, false, false, false))

            var modifier = 1
            let first_param_payload = parse_decimal(read(buffer), 2) else:
                return Option[Event].none

            let first_param = first_param_payload.value
            var next_index = first_param_payload.next_index

            match get_ref_byte(buffer, next_index):
                Option.some as separator_payload:
                    if separator_payload.value == 59:
                        next_index += 1
                        let modifier_payload = parse_decimal(read(buffer), next_index) else:
                            return Option[Event].none

                        modifier = modifier_payload.value
                        next_index = modifier_payload.next_index

                    match get_ref_byte(buffer, next_index):
                        Option.some as final_payload:
                            let final_byte = final_payload.value
                            consume_bytes(buffer, next_index + 1)
                            if final_byte == 126:
                                var event_ = key_event(KeyCode.unknown, 0, false, false, false, false)
                                if first_param == 1:
                                    event_ = key_event(KeyCode.home, 0, false, false, false, false)
                                else if first_param == 2:
                                    event_ = key_event(KeyCode.insert, 0, false, false, false, false)
                                else if first_param == 3:
                                    event_ = key_event(KeyCode.delete, 0, false, false, false, false)
                                else if first_param == 4:
                                    event_ = key_event(KeyCode.end, 0, false, false, false, false)
                                else if first_param == 5:
                                    event_ = key_event(KeyCode.page_up, 0, false, false, false, false)
                                else if first_param == 6:
                                    event_ = key_event(KeyCode.page_down, 0, false, false, false, false)

                                apply_modifier(ref_of(event_.key), modifier)
                                return Option[Event].some(value = event_)

                            if (
                                final_byte == 65
                                or final_byte == 66
                                or final_byte == 67
                                or final_byte == 68
                                or final_byte == 72
                                or final_byte == 70
                            ):
                                return Option[Event].some(value = parse_csi_letter(buffer, final_byte, modifier))

                            return Option[Event].some(value = key_event(KeyCode.unknown, 0, false, false, false, false))
                        Option.none:
                            return Option[Event].none
                Option.none:
                    return Option[Event].none
        Option.none:
            return Option[Event].none


function parse_event(buffer: ref[vec.Vec[ubyte]]) -> Option[Event]:
    match get_byte(read(buffer), 0):
        Option.some as payload:
            let first = payload.value
            if first != 27:
                consume_bytes(buffer, 1)
                return Option[Event].some(value = parse_simple_key(first, false))

            match get_byte(read(buffer), 1):
                Option.some as next_payload:
                    let second = next_payload.value
                    if second == 91:
                        return parse_csi_event(buffer)
                    if second == 79:
                        return parse_ss3_event(buffer)

                    consume_bytes(buffer, 2)
                    return Option[Event].some(value = parse_simple_key(second, true))
                Option.none:
                    consume_bytes(buffer, 1)
                    return Option[Event].some(value = key_event(KeyCode.escape, 0, false, false, false, false))
        Option.none:
            return Option[Event].none


public function stdin_is_tty() -> bool:
    return c.mt_terminal_stdin_is_tty()


public function stdout_is_tty() -> bool:
    return c.mt_terminal_stdout_is_tty()


public function stderr_is_tty() -> bool:
    return c.mt_terminal_stderr_is_tty()


public function size() -> Result[Size, Error]:
    return get_size_internal()


public function write_stdout(text: str) -> Result[ptr_uint, Error]:
    var data: const_ptr[ubyte]? = null
    if text.len != 0:
        data = unsafe: const_ptr[ubyte]<-text.data

    return write_stdout_bytes(data, text.len, "terminal write failed")


public function write_stderr(text: str) -> Result[ptr_uint, Error]:
    var data: const_ptr[ubyte]? = null
    if text.len != 0:
        data = unsafe: const_ptr[ubyte]<-text.data

    return write_stderr_bytes(data, text.len, "terminal write failed")


public function flush_stdout() -> Result[bool, Error]:
    return flush_stdout_internal()


public function flush_stderr() -> Result[bool, Error]:
    return flush_stderr_internal()


public function clear_screen() -> Result[bool, Error]:
    var sequence = string.String.with_capacity(8)
    defer sequence.release()
    append_csi(ref_of(sequence), "2J")
    append_csi(ref_of(sequence), "H")
    return write_stdout_sequence(sequence, "terminal clear screen failed")


public function clear_line() -> Result[bool, Error]:
    var sequence = string.String.with_capacity(5)
    defer sequence.release()
    append_csi(ref_of(sequence), "2K")
    return write_stdout_sequence(sequence, "terminal clear line failed")


public function cursor_home() -> Result[bool, Error]:
    var sequence = string.String.with_capacity(4)
    defer sequence.release()
    append_csi(ref_of(sequence), "H")
    return write_stdout_sequence(sequence, "terminal cursor home failed")


public function move_cursor(row: int, column: int) -> Result[bool, Error]:
    var sequence = string.String.with_capacity(24)
    defer sequence.release()
    append_escape(ref_of(sequence))
    sequence.append_format(f"[#{clamp_cursor_position(row)};#{clamp_cursor_position(column)}H")
    return write_stdout_sequence(sequence, "terminal move cursor failed")


public function hide_cursor() -> Result[bool, Error]:
    var sequence = string.String.with_capacity(8)
    defer sequence.release()
    append_csi(ref_of(sequence), "?25l")
    return write_stdout_sequence(sequence, "terminal hide cursor failed")


public function show_cursor() -> Result[bool, Error]:
    var sequence = string.String.with_capacity(8)
    defer sequence.release()
    append_csi(ref_of(sequence), "?25h")
    return write_stdout_sequence(sequence, "terminal show cursor failed")


public function enter_alternate_screen() -> Result[bool, Error]:
    var sequence = string.String.with_capacity(10)
    defer sequence.release()
    append_csi(ref_of(sequence), "?1049h")
    return write_stdout_sequence(sequence, "terminal alternate screen failed")


public function leave_alternate_screen() -> Result[bool, Error]:
    var sequence = string.String.with_capacity(10)
    defer sequence.release()
    append_csi(ref_of(sequence), "?1049l")
    return write_stdout_sequence(sequence, "terminal alternate screen failed")


public function enable_mouse() -> Result[bool, Error]:
    var sequence = string.String.with_capacity(24)
    defer sequence.release()
    append_csi(ref_of(sequence), "?1000h")
    append_csi(ref_of(sequence), "?1002h")
    append_csi(ref_of(sequence), "?1006h")
    return write_stdout_sequence(sequence, "terminal mouse enable failed")


public function disable_mouse() -> Result[bool, Error]:
    var sequence = string.String.with_capacity(24)
    defer sequence.release()
    append_csi(ref_of(sequence), "?1006l")
    append_csi(ref_of(sequence), "?1002l")
    append_csi(ref_of(sequence), "?1000l")
    return write_stdout_sequence(sequence, "terminal mouse disable failed")


public function set_foreground(color: Color) -> Result[bool, Error]:
    var sequence = string.String.with_capacity(10)
    defer sequence.release()
    append_escape(ref_of(sequence))
    sequence.append("[")
    append_color_code(ref_of(sequence), color, false)
    sequence.append("m")
    return write_stdout_sequence(sequence, "terminal foreground color failed")


public function set_background(color: Color) -> Result[bool, Error]:
    var sequence = string.String.with_capacity(10)
    defer sequence.release()
    append_escape(ref_of(sequence))
    sequence.append("[")
    append_color_code(ref_of(sequence), color, true)
    sequence.append("m")
    return write_stdout_sequence(sequence, "terminal background color failed")


public function set_rgb_foreground(red: int, green: int, blue: int) -> Result[bool, Error]:
    var sequence = string.String.with_capacity(24)
    defer sequence.release()
    append_escape(ref_of(sequence))
    sequence.append_format(
        f"[38;2;#{clamp_color_channel(red)};#{clamp_color_channel(green)};#{clamp_color_channel(blue)}m"
    )
    return write_stdout_sequence(sequence, "terminal foreground color failed")


public function set_rgb_background(red: int, green: int, blue: int) -> Result[bool, Error]:
    var sequence = string.String.with_capacity(24)
    defer sequence.release()
    append_escape(ref_of(sequence))
    sequence.append_format(
        f"[48;2;#{clamp_color_channel(red)};#{clamp_color_channel(green)};#{clamp_color_channel(blue)}m"
    )
    return write_stdout_sequence(sequence, "terminal background color failed")


public function set_bold(enabled: bool) -> Result[bool, Error]:
    var sequence = string.String.with_capacity(6)
    defer sequence.release()
    if enabled:
        append_csi(ref_of(sequence), "1m")
    else:
        append_csi(ref_of(sequence), "22m")
    return write_stdout_sequence(sequence, "terminal bold styling failed")


public function set_underline(enabled: bool) -> Result[bool, Error]:
    var sequence = string.String.with_capacity(6)
    defer sequence.release()
    if enabled:
        append_csi(ref_of(sequence), "4m")
    else:
        append_csi(ref_of(sequence), "24m")
    return write_stdout_sequence(sequence, "terminal underline styling failed")


public function reset_style() -> Result[bool, Error]:
    var sequence = string.String.with_capacity(5)
    defer sequence.release()
    append_csi(ref_of(sequence), "0m")
    return write_stdout_sequence(sequence, "terminal style reset failed")


extending Terminal:
    public static function create() -> Terminal:
        return Terminal(
                input = vec.Vec[ubyte].with_capacity(64),
                size = Size(width = 0, height = 0),
                raw_mode = false,
                alternate_screen = false,
                cursor_hidden = false,
                mouse_enabled = false
            )


    public editable function refresh_size() -> Result[Size, Error]:
        match get_size_internal():
            Result.failure as payload:
                return Result[Size, Error].failure(error= payload.error)
            Result.success as payload:
                this.size = payload.value
                return Result[Size, Error].success(value= this.size)


    public function current_size() -> Size:
        return this.size


    public editable function write(text: str) -> Result[ptr_uint, Error]:
        return write_stdout(text)


    public editable function write_error(text: str) -> Result[ptr_uint, Error]:
        return write_stderr(text)


    public editable function flush() -> Result[bool, Error]:
        return flush_stdout_internal()


    public editable function flush_error() -> Result[bool, Error]:
        return flush_stderr_internal()


    public editable function enter_raw_mode() -> Result[bool, Error]:
        if this.raw_mode:
            return Result[bool, Error].success(value= true)

        match raw_mode_enter():
            Result.failure as payload:
                return Result[bool, Error].failure(error= payload.error)
            Result.success as payload:
                this.raw_mode = payload.value
                return Result[bool, Error].success(value= true)


    public editable function leave_raw_mode() -> Result[bool, Error]:
        if not this.raw_mode:
            return Result[bool, Error].success(value= true)

        match raw_mode_leave():
            Result.failure as payload:
                return Result[bool, Error].failure(error= payload.error)
            Result.success as payload:
                this.raw_mode = false
                return Result[bool, Error].success(value= payload.value)


    public editable function enter_alternate_screen() -> Result[bool, Error]:
        if this.alternate_screen:
            return Result[bool, Error].success(value= true)

        match enter_alternate_screen():
            Result.failure as payload:
                return Result[bool, Error].failure(error= payload.error)
            Result.success as payload:
                this.alternate_screen = payload.value
                return Result[bool, Error].success(value= true)


    public editable function leave_alternate_screen() -> Result[bool, Error]:
        if not this.alternate_screen:
            return Result[bool, Error].success(value= true)

        match leave_alternate_screen():
            Result.failure as payload:
                return Result[bool, Error].failure(error= payload.error)
            Result.success as payload:
                this.alternate_screen = false
                return Result[bool, Error].success(value= payload.value)


    public editable function hide_cursor() -> Result[bool, Error]:
        if this.cursor_hidden:
            return Result[bool, Error].success(value= true)

        match hide_cursor():
            Result.failure as payload:
                return Result[bool, Error].failure(error= payload.error)
            Result.success as payload:
                this.cursor_hidden = payload.value
                return Result[bool, Error].success(value= true)


    public editable function show_cursor() -> Result[bool, Error]:
        if not this.cursor_hidden:
            return Result[bool, Error].success(value= true)

        match show_cursor():
            Result.failure as payload:
                return Result[bool, Error].failure(error= payload.error)
            Result.success as payload:
                this.cursor_hidden = false
                return Result[bool, Error].success(value= payload.value)


    public editable function enable_mouse() -> Result[bool, Error]:
        if this.mouse_enabled:
            return Result[bool, Error].success(value= true)

        match enable_mouse():
            Result.failure as payload:
                return Result[bool, Error].failure(error= payload.error)
            Result.success as payload:
                this.mouse_enabled = payload.value
                return Result[bool, Error].success(value= true)


    public editable function disable_mouse() -> Result[bool, Error]:
        if not this.mouse_enabled:
            return Result[bool, Error].success(value= true)

        match disable_mouse():
            Result.failure as payload:
                return Result[bool, Error].failure(error= payload.error)
            Result.success as payload:
                this.mouse_enabled = false
                return Result[bool, Error].success(value= payload.value)


    public editable function poll_event(timeout_ms: int) -> Result[Option[Event], Error]:
        if stdout_is_tty():
            match get_size_internal():
                Result.failure as payload:
                    return Result[Option[Event], Error].failure(error= payload.error)
                Result.success as payload:
                    let current = payload.value
                    if current.width != this.size.width or current.height != this.size.height:
                        this.size = current
                        return Result[
                            Option[Event],
                            Error
                        ].success(value= Option[Event].some(value = resize_event(current)))

        match parse_event(ref_of(this.input)):
            Option.some as payload:
                return Result[Option[Event], Error].success(value= Option[Event].some(value = payload.value))
            Option.none:
                pass

        match read_stdin(timeout_ms):
            Result.failure as payload:
                return Result[Option[Event], Error].failure(error= payload.error)
            Result.success as payload:
                var bytes = payload.value
                defer bytes.release()
                if not bytes.is_empty():
                    this.input.append_span(bytes.as_span())

        match parse_event(ref_of(this.input)):
            Option.some as payload:
                return Result[Option[Event], Error].success(value= Option[Event].some(value = payload.value))
            Option.none:
                return Result[Option[Event], Error].success(value= Option[Event].none)


    public editable function release() -> void:
        if this.mouse_enabled:
            match disable_mouse():
                Result.failure as payload:
                    var error = payload.error
                    error.release()
                Result.success:
                    pass
            this.mouse_enabled = false

        if this.cursor_hidden:
            match show_cursor():
                Result.failure as payload:
                    var error = payload.error
                    error.release()
                Result.success:
                    pass
            this.cursor_hidden = false

        if this.alternate_screen:
            match leave_alternate_screen():
                Result.failure as payload:
                    var error = payload.error
                    error.release()
                Result.success:
                    pass
            this.alternate_screen = false

        if this.raw_mode:
            match raw_mode_leave():
                Result.failure as payload:
                    var error = payload.error
                    error.release()
                Result.success:
                    pass
            this.raw_mode = false

        this.input.release()


extending Error:
    public editable function release() -> void:
        this.message.release()
