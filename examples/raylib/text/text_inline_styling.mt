module examples.raylib.text.text_inline_styling

import std.c.libc as libc
import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [text] example - inline styling"
const foreground_text: cstr = c"This changes the [cFF0000FF]foreground color[r] of provided text!!!"
const background_text: cstr = c"This changes the [bFF00FFFF]background color[r] of provided text!!!"
const both_text: cstr = c"This changes the [c00ff00ff][bff0000ff]foreground and background colors[r]!!!"
const alpha_text: cstr = c"This changes the [c00ff00ff]alpha[r] relative [cffffffff][b000000ff]from source[r] [cff000088]color[r]!!!"
const creative_format: cstr = c"Let's be [c%02x%02x%02xFF]CREATIVE[r] !!!"


def draw_text_styled(font: rl.Font, text: cstr, position: rl.Vector2, font_size: f32, spacing: f32, color: rl.Color) -> void:
    var active_font = font
    if active_font.texture.id == 0:
        active_font = rl.GetFontDefault()

    let text_len = i32<-rl.TextLength(text)
    var col_front = color
    var col_back = rl.BLANK
    let back_rec_padding = 4.0

    var text_offset_y: f32 = 0.0
    var text_offset_x: f32 = 0.0
    let text_line_spacing: f32 = 0.0
    let scale_factor = font_size / f32<-active_font.baseSize

    unsafe:
        let raw_text = ptr[char]<-text
        var index = 0
        while index < text_len:
            let current_ptr = raw_text + index
            var codepoint_byte_count = 0
            let codepoint = rl.GetCodepointNext(cstr<-current_ptr, ptr_of(ref_of(codepoint_byte_count)))

            if codepoint == 10:
                text_offset_y += font_size + text_line_spacing
                text_offset_x = 0.0
                index += codepoint_byte_count
                continue

            if codepoint == 91:
                if index + 2 < text_len and read(current_ptr + 1) == char<-114 and read(current_ptr + 2) == char<-93:
                    col_front = color
                    col_back = rl.BLANK
                    index += 3
                    continue
                elif index + 1 < text_len and (read(current_ptr + 1) == char<-99 or read(current_ptr + 1) == char<-98):
                    let color_kind = read(current_ptr + 1)
                    let color_ptr = current_ptr + 2
                    var color_text = zero[array[char, 9]]()
                    var color_count = 0

                    while read(color_ptr + color_count) != char<-0 and read(color_ptr + color_count) != char<-93:
                        let digit = read(color_ptr + color_count)
                        if (digit >= char<-48 and digit <= char<-57) or (digit >= char<-65 and digit <= char<-70) or (digit >= char<-97 and digit <= char<-102):
                            color_text[color_count] = digit
                            color_count += 1
                        else:
                            break

                    let color_value = libc.strtoul(cstr<-ptr_of(ref_of(color_text[0])), null, 16)
                    if color_kind == char<-99:
                        col_front = rl.GetColor(u32<-color_value)
                    elif color_kind == char<-98:
                        col_back = rl.GetColor(u32<-color_value)

                    index += color_count + 3
                    continue

            let glyph_index = rl.GetGlyphIndex(active_font, codepoint)
            var increase_x: f32 = 0.0
            if active_font.glyphs[glyph_index].advanceX == 0:
                increase_x = f32<-active_font.recs[glyph_index].width * scale_factor + spacing
            else:
                increase_x += f32<-active_font.glyphs[glyph_index].advanceX * scale_factor + spacing

            if col_back.a > 0:
                rl.DrawRectangleRec(
                    rl.Rectangle(
                        x = position.x + text_offset_x,
                        y = position.y + text_offset_y - back_rec_padding,
                        width = increase_x,
                        height = font_size + 2.0 * back_rec_padding,
                    ),
                    col_back,
                )

            if codepoint != 32 and codepoint != 9:
                rl.DrawTextCodepoint(active_font, codepoint, rl.Vector2(x = position.x + text_offset_x, y = position.y + text_offset_y), font_size, col_front)

            text_offset_x += increase_x
            index += codepoint_byte_count


def measure_text_styled(font: rl.Font, text: cstr, font_size: f32, spacing: f32) -> rl.Vector2:
    let empty_size = rl.Vector2(x = 0.0, y = 0.0)
    let text_len = i32<-rl.TextLength(text)
    if text_len == 0:
        return empty_size

    unsafe:
        let raw_text = ptr[char]<-text
        var active_font = font
        if active_font.texture.id == 0:
            active_font = rl.GetFontDefault()

        var text_width: f32 = 0.0
        let text_height = font_size
        let scale_factor = font_size / f32<-active_font.baseSize
        var valid_codepoint_counter = 0

        var index = 0
        while index < text_len:
            let current_ptr = raw_text + index
            var codepoint_byte_count = 0
            let codepoint = rl.GetCodepointNext(cstr<-current_ptr, ptr_of(ref_of(codepoint_byte_count)))

            if codepoint == 91:
                if index + 2 < text_len and read(current_ptr + 1) == char<-114 and read(current_ptr + 2) == char<-93:
                    index += 3
                    continue
                elif index + 1 < text_len and (read(current_ptr + 1) == char<-99 or read(current_ptr + 1) == char<-98):
                    let color_ptr = current_ptr + 2
                    var color_count = 0

                    while read(color_ptr + color_count) != char<-0 and read(color_ptr + color_count) != char<-93:
                        let digit = read(color_ptr + color_count)
                        if (digit >= char<-48 and digit <= char<-57) or (digit >= char<-65 and digit <= char<-70) or (digit >= char<-97 and digit <= char<-102):
                            color_count += 1
                        else:
                            break

                    index += color_count + 3
                    continue

            if codepoint != 10:
                let glyph_index = rl.GetGlyphIndex(active_font, codepoint)
                if active_font.glyphs[glyph_index].advanceX > 0:
                    text_width += f32<-active_font.glyphs[glyph_index].advanceX
                else:
                    text_width += f32<-(active_font.recs[glyph_index].width + active_font.glyphs[glyph_index].offsetX)

                valid_codepoint_counter += 1

            index += codepoint_byte_count

        return rl.Vector2(
            x = text_width * scale_factor + f32<-(valid_codepoint_counter - 1) * spacing,
            y = text_height,
        )


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var text_size = rl.Vector2(x = 0.0, y = 0.0)
    var col_random = rl.RED
    var frame_counter = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        frame_counter += 1

        if (frame_counter % 20) == 0:
            col_random.r = u8<-rl.GetRandomValue(0, 255)
            col_random.g = u8<-rl.GetRandomValue(0, 255)
            col_random.b = u8<-rl.GetRandomValue(0, 255)
            col_random.a = 255

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        draw_text_styled(rl.GetFontDefault(), foreground_text, rl.Vector2(x = 100.0, y = 80.0), 20.0, 2.0, rl.BLACK)
        draw_text_styled(rl.GetFontDefault(), background_text, rl.Vector2(x = 100.0, y = 120.0), 20.0, 2.0, rl.BLACK)
        draw_text_styled(rl.GetFontDefault(), both_text, rl.Vector2(x = 100.0, y = 160.0), 20.0, 2.0, rl.BLACK)
        draw_text_styled(rl.GetFontDefault(), alpha_text, rl.Vector2(x = 100.0, y = 200.0), 20.0, 2.0, rl.Color(r = 0, g = 0, b = 0, a = 100))

        let creative_text = rl.TextFormat(creative_format, i32<-col_random.r, i32<-col_random.g, i32<-col_random.b)
        draw_text_styled(rl.GetFontDefault(), creative_text, rl.Vector2(x = 100.0, y = 240.0), 40.0, 2.0, rl.BLACK)

        text_size = measure_text_styled(rl.GetFontDefault(), creative_text, 40.0, 2.0)
        rl.DrawRectangleLines(100, 240, i32<-text_size.x, i32<-text_size.y, rl.GREEN)

    return 0
