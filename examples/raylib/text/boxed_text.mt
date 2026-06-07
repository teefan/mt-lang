import std.raylib as rl
import std.str as text


function draw_chars_wrapped(
    font: rl.Font,
    line_text: str,
    rec: rl.Rectangle,
    font_size: float,
    spacing: float,
    tint: rl.Color,
    start_y: float
) -> float:
    var current_line = zero[str_buffer[1024]]
    let line_height = font_size + font_size / 2.0
    var offset_y = start_y
    let length = int<-rl.text_length(line_text)

    var index = 0
    while index < length:
        var codepoint_byte_count = 0
        let codepoint = rl.get_codepoint_next(
            line_text.slice(ptr_uint<-index, ptr_uint<-(length - index)),
            codepoint_byte_count
        )
        var advance = codepoint_byte_count
        if codepoint == 0x3f:
            advance = 1

        let glyph_text = line_text.slice(ptr_uint<-index, ptr_uint<-advance)
        var candidate = zero[str_buffer[1024]]
        candidate.assign(current_line.as_str())
        candidate.append(glyph_text)

        if current_line.len() == 0 or rl.measure_text_ex(font, candidate.as_str(), font_size, spacing).x <= rec.width:
            current_line.assign(candidate.as_str())
        else:
            if offset_y + font_size > rec.height:
                return offset_y

            rl.draw_text_ex(
                font,
                current_line.as_str(),
                rl.Vector2(x = rec.x, y = rec.y + offset_y),
                font_size,
                spacing,
                tint
            )
            offset_y += line_height
            current_line.assign(glyph_text)

        index += advance

    if current_line.len() > 0 and offset_y + font_size <= rec.height:
        rl.draw_text_ex(
            font,
            current_line.as_str(),
            rl.Vector2(x = rec.x, y = rec.y + offset_y),
            font_size,
            spacing,
            tint
        )
        offset_y += line_height

    return offset_y


function draw_words_wrapped(
    font: rl.Font,
    line_text: str,
    rec: rl.Rectangle,
    font_size: float,
    spacing: float,
    tint: rl.Color,
    start_y: float
) -> float:
    var word_count = 0
    let words = rl.text_split_ptr(line_text, char<-32, word_count)
    let line_height = font_size + font_size / 2.0
    var offset_y = start_y
    var current_line = zero[str_buffer[1024]]

    var index = 0
    while index < word_count:
        let word = unsafe: text.chars_as_str(read(words + ptr_uint<-index))
        var candidate = zero[str_buffer[1024]]
        candidate.assign(current_line.as_str())
        if current_line.len() > 0:
            candidate.append(" ")
        candidate.append(word)

        if current_line.len() == 0 or rl.measure_text_ex(font, candidate.as_str(), font_size, spacing).x <= rec.width:
            current_line.assign(candidate.as_str())
        else:
            if offset_y + font_size > rec.height:
                return offset_y

            rl.draw_text_ex(
                font,
                current_line.as_str(),
                rl.Vector2(x = rec.x, y = rec.y + offset_y),
                font_size,
                spacing,
                tint
            )
            offset_y += line_height
            current_line.assign(word)

        index += 1

    if current_line.len() > 0 and offset_y + font_size <= rec.height:
        rl.draw_text_ex(
            font,
            current_line.as_str(),
            rl.Vector2(x = rec.x, y = rec.y + offset_y),
            font_size,
            spacing,
            tint
        )
        offset_y += line_height

    return offset_y


public function draw_text_boxed(
    font: rl.Font,
    body_text: str,
    rec: rl.Rectangle,
    font_size: float,
    spacing: float,
    word_wrap: bool,
    tint: rl.Color
) -> void:
    var line_count = 0
    let raw_lines = rl.load_text_lines(body_text, ptr_of(line_count))
    defer rl.unload_text_lines(raw_lines, line_count)

    var offset_y = float<-0.0
    var line_index = 0
    while line_index < line_count:
        let line_text = unsafe: text.chars_as_str(read(raw_lines + ptr_uint<-line_index))
        if word_wrap:
            offset_y = draw_words_wrapped(font, line_text, rec, font_size, spacing, tint, offset_y)
        else:
            offset_y = draw_chars_wrapped(font, line_text, rec, font_size, spacing, tint, offset_y)

        if offset_y + font_size > rec.height:
            return

        if line_index + 1 < line_count:
            offset_y += font_size / 2.0

        line_index += 1
