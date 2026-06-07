import std.libc as libc
import std.raylib as rl
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function is_hex_digit(text: str) -> bool:
    var size = 0
    let codepoint = rl.get_codepoint(text, size)
    return (codepoint >= 48 and codepoint <= 57) or (codepoint >= 65 and codepoint <= 70) or (codepoint >= 97 and codepoint <= 102)


function draw_text_styled(
    font_arg: rl.Font,
    styled_text: str,
    position: rl.Vector2,
    font_size: float,
    spacing: float,
    color: rl.Color
) -> void:
    var font = font_arg
    if font.texture.id == 0:
        font = rl.get_font_default()

    let text_len = int<-rl.text_length(styled_text)
    var front_color = color
    var back_color = rl.BLANK
    let back_padding = float<-4.0
    var text_offset_y = float<-0.0
    var text_offset_x = float<-0.0
    let scale_factor = font_size / float<-font.baseSize

    var index = 0
    while index < text_len:
        var codepoint_byte_count = 0
        let codepoint = rl.get_codepoint_next(
            styled_text.slice(ptr_uint<-index, ptr_uint<-(text_len - index)),
            codepoint_byte_count
        )
        var advance = codepoint_byte_count
        if codepoint == 0x3f:
            advance = 1

        if codepoint == 10:
            text_offset_y += font_size
            text_offset_x = 0.0
            index += advance
            continue

        if codepoint == 91:
            if index + 2 < text_len and styled_text.slice(
                ptr_uint<-(index + 1),
                ptr_uint<-1
            ).equal("r") and styled_text.slice(ptr_uint<-(index + 2), ptr_uint<-1).equal("]"):
                front_color = color
                back_color = rl.BLANK
                index += 3
                continue
            if index + 1 < text_len:
                let marker = styled_text.slice(ptr_uint<-(index + 1), ptr_uint<-1)
                if marker.equal("c") or marker.equal("b"):
                    var hex_len = 0
                    while index + 2 + hex_len < text_len and not styled_text.slice(
                        ptr_uint<-(index + 2 + hex_len),
                        ptr_uint<-1
                    ).equal("]"):
                        let hex_char = styled_text.slice(ptr_uint<-(index + 2 + hex_len), ptr_uint<-1)
                        if not is_hex_digit(hex_char):
                            break
                        hex_len += 1

                    if hex_len > 0 and index + 2 + hex_len < text_len and styled_text.slice(
                        ptr_uint<-(index + 2 + hex_len),
                        ptr_uint<-1
                    ).equal("]"):
                        let hex_text = styled_text.slice(ptr_uint<-(index + 2), ptr_uint<-hex_len)
                        let hex_value = uint<-libc.parse_ulong_to_end(hex_text, null, 16)
                        if marker.equal("c"):
                            front_color = rl.get_color(hex_value)
                        else:
                            back_color = rl.get_color(hex_value)
                        index += hex_len + 3
                        continue

        let glyph_index = rl.get_glyph_index(font, codepoint)
        var glyph_advance_x = 0
        var glyph_width = float<-0.0
        unsafe:
            glyph_advance_x = read(font.glyphs + ptr_uint<-glyph_index).advanceX
            glyph_width = read(font.recs + ptr_uint<-glyph_index).width

        var increase_x = float<-0.0
        if glyph_advance_x == 0:
            increase_x = float<-glyph_width * scale_factor + spacing
        else:
            increase_x = float<-glyph_advance_x * scale_factor + spacing

        if back_color.a > 0:
            rl.draw_rectangle_rec(
                rl.Rectangle(
                    x = position.x + text_offset_x,
                    y = position.y + text_offset_y - back_padding,
                    width = increase_x,
                    height = font_size + 2.0 * back_padding
                ),
                back_color
            )

        if codepoint != 32 and codepoint != 9:
            rl.draw_text_codepoint(
                font,
                codepoint,
                rl.Vector2(x = position.x + text_offset_x, y = position.y + text_offset_y),
                font_size,
                front_color
            )

        text_offset_x += increase_x
        index += advance


function measure_text_styled(font_arg: rl.Font, styled_text: str, font_size: float, spacing: float) -> rl.Vector2:
    var font = font_arg
    if font.texture.id == 0 or rl.text_length(styled_text) == uint<-0:
        return rl.Vector2(x = 0.0, y = 0.0)
    if font.texture.id == 0:
        font = rl.get_font_default()

    let text_len = int<-rl.text_length(styled_text)
    var text_width = float<-0.0
    let text_height = font_size
    let scale_factor = font_size / float<-font.baseSize
    var valid_codepoint_counter = 0

    var index = 0
    while index < text_len:
        var codepoint_byte_count = 0
        let codepoint = rl.get_codepoint_next(
            styled_text.slice(ptr_uint<-index, ptr_uint<-(text_len - index)),
            codepoint_byte_count
        )
        var advance = codepoint_byte_count
        if codepoint == 0x3f:
            advance = 1

        if codepoint == 91:
            if index + 2 < text_len and styled_text.slice(
                ptr_uint<-(index + 1),
                ptr_uint<-1
            ).equal("r") and styled_text.slice(ptr_uint<-(index + 2), ptr_uint<-1).equal("]"):
                index += 3
                continue
            if index + 1 < text_len:
                let marker = styled_text.slice(ptr_uint<-(index + 1), ptr_uint<-1)
                if marker.equal("c") or marker.equal("b"):
                    var hex_len = 0
                    while index + 2 + hex_len < text_len and not styled_text.slice(
                        ptr_uint<-(index + 2 + hex_len),
                        ptr_uint<-1
                    ).equal("]"):
                        let hex_char = styled_text.slice(ptr_uint<-(index + 2 + hex_len), ptr_uint<-1)
                        if not is_hex_digit(hex_char):
                            break
                        hex_len += 1

                    if hex_len > 0 and index + 2 + hex_len < text_len and styled_text.slice(
                        ptr_uint<-(index + 2 + hex_len),
                        ptr_uint<-1
                    ).equal("]"):
                        index += hex_len + 3
                        continue

        if codepoint != 10:
            let glyph_index = rl.get_glyph_index(font, codepoint)
            var glyph_advance_x = 0
            var glyph_width = float<-0.0
            var glyph_offset_x = 0
            unsafe:
                glyph_advance_x = read(font.glyphs + ptr_uint<-glyph_index).advanceX
                glyph_width = read(font.recs + ptr_uint<-glyph_index).width
                glyph_offset_x = read(font.glyphs + ptr_uint<-glyph_index).offsetX

            if glyph_advance_x > 0:
                text_width += float<-glyph_advance_x
            else:
                text_width += float<-(glyph_width + glyph_offset_x)
            valid_codepoint_counter += 1

        index += advance

    return rl.Vector2(x = text_width * scale_factor + float<-(valid_codepoint_counter - 1) * spacing, y = text_height)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [text] example - inline styling")
    defer rl.close_window()

    var text_size = rl.Vector2(x = 0.0, y = 0.0)
    var random_color = rl.RED
    var frame_counter = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        frame_counter += 1
        if (frame_counter % 20) == 0:
            random_color.r = ubyte<-rl.get_random_value(0, 255)
            random_color.g = ubyte<-rl.get_random_value(0, 255)
            random_color.b = ubyte<-rl.get_random_value(0, 255)
            random_color.a = 255

        let dynamic_text = text.cstr_as_str(rl.text_format(
            "Let's be [c%02x%02x%02xFF]CREATIVE[r] !!!",
            random_color.r,
            random_color.g,
            random_color.b
        ))
        text_size = measure_text_styled(rl.get_font_default(), dynamic_text, 40.0, 2.0)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        draw_text_styled(
            rl.get_font_default(),
            "This changes the [cFF0000FF]foreground color[r] of provided text!!!",
            rl.Vector2(x = 100.0, y = 80.0),
            20.0,
            2.0,
            rl.BLACK
        )
        draw_text_styled(
            rl.get_font_default(),
            "This changes the [bFF00FFFF]background color[r] of provided text!!!",
            rl.Vector2(x = 100.0, y = 120.0),
            20.0,
            2.0,
            rl.BLACK
        )
        draw_text_styled(
            rl.get_font_default(),
            "This changes the [c00ff00ff][bff0000ff]foreground and background colors[r]!!!",
            rl.Vector2(x = 100.0, y = 160.0),
            20.0,
            2.0,
            rl.BLACK
        )
        draw_text_styled(
            rl.get_font_default(),
            "This changes the [c00ff00ff]alpha[r] relative [cffffffff][b000000ff]from source[r] [cff000088]color[r]!!!",
            rl.Vector2(x = 100.0, y = 200.0),
            20.0,
            2.0,
            rl.Color(r = 0, g = 0, b = 0, a = 100)
        )
        draw_text_styled(rl.get_font_default(), dynamic_text, rl.Vector2(x = 100.0, y = 240.0), 40.0, 2.0, rl.BLACK)
        rl.draw_rectangle_lines(100, 240, int<-text_size.x, int<-text_size.y, rl.GREEN)

        rl.end_drawing()

    return 0
