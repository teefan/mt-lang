import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as math
import std.str as text
import std.string as string
import std.vec as vec

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const FILE_NAME: str = "text_file.txt"


function release_string_values(values: ref[vec.Vec[string.String]]) -> void:
    var index: ptr_uint = 0
    while index < values.len():
        let value_ptr = values.get(index) else:
            fatal(c"text_file_loading missing value")

        unsafe:
            var owned = read(value_ptr)
            owned.release()

        index += 1

    values.release()


function next_word_break(line: str, start: ptr_uint) -> ptr_uint:
    var index = start
    while index < line.len and line.byte_at(index) != ubyte<-32:
        index += 1
    return index


function append_wrapped_line(line: str, font_size: int, wrap_width: int, output: ref[vec.Vec[string.String]]) -> void:
    if line.len == 0:
        output.push(string.String.from_str(""))
        return

    var start: ptr_uint = 0
    while start < line.len:
        let word_end = next_word_break(line, start)
        var candidate_end = word_end
        var last_fit_end = start

        while true:
            let segment = line.slice(start, candidate_end - start)
            if candidate_end == start or rl.measure_text(segment, font_size) <= wrap_width:
                last_fit_end = candidate_end
                if candidate_end >= line.len:
                    break
                candidate_end = next_word_break(line, candidate_end + 1)
                continue

            break

        if last_fit_end == start:
            last_fit_end = word_end

        output.push(string.String.from_str(line.slice(start, last_fit_end - start)))

        if last_fit_end >= line.len:
            break

        start = last_fit_end + 1


function wrap_file_text(content: str, font_size: int, wrap_width: int, output: ref[vec.Vec[string.String]]) -> void:
    var start: ptr_uint = 0
    var index: ptr_uint = 0

    while index <= content.len:
        if index == content.len or content.byte_at(index) == ubyte<-10:
            var line = content.slice(start, index - start)
            if line.len > 0 and line.byte_at(line.len - 1) == ubyte<-13:
                line = line.slice(0, line.len - 1)
            append_wrapped_line(line, font_size, wrap_width, output)
            start = index + 1

        index += 1


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - text file loading")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var cam = rl.Camera2D(
        offset = rl.Vector2(x = 0.0, y = 0.0),
        target = rl.Vector2(x = 0.0, y = 0.0),
        rotation = 0.0,
        zoom = 1.0
    )

    let raw_text = rl.load_file_text(FILE_NAME) else:
        fatal("could not load examples/raylib/resources/text_file.txt")
    defer rl.unload_file_text(raw_text)

    let font_size = 20
    let text_top = 25 + font_size
    let wrap_width = SCREEN_WIDTH - 20
    let file_text = text.chars_as_str(raw_text)

    var wrapped_lines = vec.Vec[string.String].create()
    defer release_string_values(ref_of(wrapped_lines))
    wrap_file_text(file_text, font_size, wrap_width, ref_of(wrapped_lines))

    var text_height = 0
    var index: ptr_uint = 0
    while index < wrapped_lines.len():
        let line = wrapped_lines.get(index) else:
            fatal(c"text_file_loading missing wrapped line")

        unsafe:
            let text_value = read(line).as_str()
            let measure_target = if text_value.len > 0: text_value else: " "
            let size = rl.measure_text_ex(rl.get_font_default(), measure_target, float<-font_size, 2.0)
            text_height += int<-size.y + 10

        index += 1

    var scroll_bar = rl.Rectangle(x = (float<-SCREEN_WIDTH) - 5.0, y = 0.0, width = 5.0, height = float<-SCREEN_HEIGHT)
    if text_height > SCREEN_HEIGHT:
        scroll_bar.height = (float<-SCREEN_HEIGHT) * 100.0 / float<-(text_height - SCREEN_HEIGHT)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let scroll = rl.get_mouse_wheel_move()
        cam.target.y -= scroll * (float<-font_size) * 1.5

        if cam.target.y < 0.0:
            cam.target.y = 0.0

        var max_scroll = (float<-text_height) - (float<-SCREEN_HEIGHT) + (float<-text_top)
        if max_scroll < 0.0:
            max_scroll = 0.0
        if cam.target.y > max_scroll:
            cam.target.y = max_scroll

        if text_height > SCREEN_HEIGHT:
            scroll_bar.y = math.lerp(
                float<-text_top,
                (float<-SCREEN_HEIGHT) - scroll_bar.height,
                (cam.target.y - float<-text_top) / float<-(text_height - SCREEN_HEIGHT)
            )

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_2d(cam)
        var index: ptr_uint = 0
        var y = text_top
        while index < wrapped_lines.len():
            let line = wrapped_lines.get(index) else:
                fatal(c"text_file_loading missing wrapped line")

            unsafe:
                let text_value = read(line).as_str()
                let measure_target = if text_value.len > 0: text_value else: " "
                let size = rl.measure_text_ex(rl.get_font_default(), measure_target, float<-font_size, 2.0)
                rl.draw_text(text_value, 10, y, font_size, rl.RED)
                y += int<-size.y + 10

            index += 1
        rl.end_mode_2d()

        rl.draw_rectangle(0, 0, SCREEN_WIDTH, text_top - 10, rl.BEIGE)
        rl.draw_text(f"File: #{FILE_NAME}", 10, 10, font_size, rl.MAROON)
        rl.draw_rectangle_rec(scroll_bar, rl.MAROON)

        rl.end_drawing()

    return 0
