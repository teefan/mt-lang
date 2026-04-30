module examples.raylib.text.text_rectangle_bounds

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [text] example - rectangle bounds"
const text: cstr = c"Text cannot escape\tthis container\t...word wrap also works when active so here's a long text for testing.\n\nLorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Nec ullamcorper sit amet risus nullam eget felis eget."
const word_wrap_label: cstr = c"Word Wrap: "
const word_wrap_on: cstr = c"ON"
const word_wrap_off: cstr = c"OFF"
const toggle_wrap_text: cstr = c"Press [SPACE] to toggle word wrap"
const resize_help_text: cstr = c"Click hold & drag the    to resize the container"

const measure_state: i32 = 0
const draw_state: i32 = 1

def draw_text_boxed(font: rl.Font, text: cstr, rec: rl.Rectangle, font_size: f32, spacing: f32, word_wrap: bool, tint: rl.Color) -> void:
    draw_text_boxed_selectable(font, text, rec, font_size, spacing, word_wrap, tint, 0, 0, rl.WHITE, rl.WHITE)

def draw_text_boxed_selectable(font: rl.Font, text: cstr, rec: rl.Rectangle, font_size: f32, spacing: f32, word_wrap: bool, tint: rl.Color, select_start: i32, select_length: i32, select_tint: rl.Color, select_back_tint: rl.Color) -> void:
    let length = i32<-rl.TextLength(text)

    var text_offset_y: f32 = 0.0
    var text_offset_x: f32 = 0.0
    let scale_factor = font_size / f32<-font.baseSize

    var state = if word_wrap then measure_state else draw_state
    var start_line = -1
    var end_line = -1
    var last_k = -1
    var select_start_mut = select_start

    unsafe:
        let raw_text = ptr[char]<-text
        var i = 0
        var k = 0
        while i < length:
            let current_ptr = raw_text + i
            var codepoint_byte_count = 0
            let codepoint = rl.GetCodepoint(cstr<-current_ptr, raw(addr(codepoint_byte_count)))
            let glyph_index = rl.GetGlyphIndex(font, codepoint)

            if codepoint == 0x3f:
                codepoint_byte_count = 1

            i += codepoint_byte_count - 1

            var glyph_width: f32 = 0.0
            if codepoint != 10:
                if font.glyphs[glyph_index].advanceX == 0:
                    glyph_width = font.recs[glyph_index].width * scale_factor
                else:
                    glyph_width = f32<-font.glyphs[glyph_index].advanceX * scale_factor

                if i + 1 < length:
                    glyph_width += spacing

            if state == measure_state:
                if codepoint == 32 or codepoint == 9 or codepoint == 10:
                    end_line = i

                if (text_offset_x + glyph_width) > rec.width:
                    end_line = if end_line < 1 then i else end_line
                    if i == end_line:
                        end_line -= codepoint_byte_count
                    if (start_line + codepoint_byte_count) == end_line:
                        end_line = i - codepoint_byte_count

                    state = draw_state
                elif (i + 1) == length:
                    end_line = i
                    state = draw_state
                elif codepoint == 10:
                    state = draw_state

                if state == draw_state:
                    text_offset_x = 0.0
                    i = start_line
                    glyph_width = 0.0

                    let tmp = last_k
                    last_k = k - 1
                    k = tmp
            else:
                if codepoint == 10:
                    if not word_wrap:
                        text_offset_y += (f32<-font.baseSize + f32<-font.baseSize / 2.0) * scale_factor
                        text_offset_x = 0.0
                else:
                    if not word_wrap and (text_offset_x + glyph_width) > rec.width:
                        text_offset_y += (f32<-font.baseSize + f32<-font.baseSize / 2.0) * scale_factor
                        text_offset_x = 0.0

                    if (text_offset_y + f32<-font.baseSize * scale_factor) > rec.height:
                        break

                    var is_glyph_selected = false
                    if select_start_mut >= 0 and k >= select_start_mut and k < (select_start_mut + select_length):
                        rl.DrawRectangleRec(
                            rl.Rectangle(
                                x = rec.x + text_offset_x - 1.0,
                                y = rec.y + text_offset_y,
                                width = glyph_width,
                                height = f32<-font.baseSize * scale_factor,
                            ),
                            select_back_tint,
                        )
                        is_glyph_selected = true

                    if codepoint != 32 and codepoint != 9:
                        rl.DrawTextCodepoint(
                            font,
                            codepoint,
                            rl.Vector2(x = rec.x + text_offset_x, y = rec.y + text_offset_y),
                            font_size,
                            if is_glyph_selected then select_tint else tint,
                        )

                if word_wrap and i == end_line:
                    text_offset_y += (f32<-font.baseSize + f32<-font.baseSize / 2.0) * scale_factor
                    text_offset_x = 0.0
                    start_line = end_line
                    end_line = -1
                    glyph_width = 0.0
                    select_start_mut += last_k - k
                    k = last_k

                    state = measure_state

            if text_offset_x != 0.0 or codepoint != 32:
                text_offset_x += glyph_width

            i += 1
            k += 1

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var resizing = false
    var word_wrap = true

    var container = rl.Rectangle(
        x = 25.0,
        y = 25.0,
        width = f32<-screen_width - 50.0,
        height = f32<-screen_height - 250.0,
    )
    var resizer = rl.Rectangle(
        x = container.x + container.width - 17.0,
        y = container.y + container.height - 17.0,
        width = 14.0,
        height = 14.0,
    )

    let min_width: f32 = 60.0
    let min_height: f32 = 60.0
    let max_width: f32 = f32<-screen_width - 50.0
    let max_height: f32 = f32<-screen_height - 160.0

    var last_mouse = rl.Vector2(x = 0.0, y = 0.0)
    var border_color = rl.MAROON
    let font = rl.GetFontDefault()

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            word_wrap = not word_wrap

        let mouse = rl.GetMousePosition()

        if rl.CheckCollisionPointRec(mouse, container):
            border_color = rl.Fade(rl.MAROON, 0.4)
        elif not resizing:
            border_color = rl.MAROON

        if resizing:
            if rl.IsMouseButtonReleased(rl.MouseButton.MOUSE_BUTTON_LEFT):
                resizing = false

            let width = container.width + (mouse.x - last_mouse.x)
            if width > min_width:
                if width < max_width:
                    container.width = width
                else:
                    container.width = max_width
            else:
                container.width = min_width

            let height = container.height + (mouse.y - last_mouse.y)
            if height > min_height:
                if height < max_height:
                    container.height = height
                else:
                    container.height = max_height
            else:
                container.height = min_height
        else:
            if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT) and rl.CheckCollisionPointRec(mouse, resizer):
                resizing = true

        resizer.x = container.x + container.width - 17.0
        resizer.y = container.y + container.height - 17.0
        last_mouse = mouse

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawRectangleLinesEx(container, 3.0, border_color)
        draw_text_boxed(
            font,
            text,
            rl.Rectangle(x = container.x + 4.0, y = container.y + 4.0, width = container.width - 4.0, height = container.height - 4.0),
            20.0,
            2.0,
            word_wrap,
            rl.GRAY,
        )

        rl.DrawRectangleRec(resizer, border_color)
        rl.DrawRectangle(0, screen_height - 54, screen_width, 54, rl.GRAY)
        rl.DrawRectangleRec(rl.Rectangle(x = 382.0, y = f32<-screen_height - 34.0, width = 12.0, height = 12.0), rl.MAROON)

        rl.DrawText(word_wrap_label, 313, screen_height - 115, 20, rl.BLACK)
        if word_wrap:
            rl.DrawText(word_wrap_on, 447, screen_height - 115, 20, rl.RED)
        else:
            rl.DrawText(word_wrap_off, 447, screen_height - 115, 20, rl.BLACK)

        rl.DrawText(toggle_wrap_text, 218, screen_height - 86, 20, rl.GRAY)
        rl.DrawText(resize_help_text, 155, screen_height - 38, 20, rl.RAYWHITE)

    return 0
