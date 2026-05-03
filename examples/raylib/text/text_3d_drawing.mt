module examples.raylib.text.text_3d_drawing

import std.c.libm as math
import std.c.raylib as rl
import std.c.rlgl as rlgl

const letter_boundary_size: f32 = 0.25
const text_max_layers: i32 = 32
const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [text] example - 3d drawing"
const alpha_discard_shader_path: cstr = c"../resources/shaders/glsl330/alpha_discard.fs"
const initial_text: cstr = c"Hello ~~World~~ in 3D!"

struct WaveTextConfig:
    wave_range: rl.Vector3
    wave_speed: rl.Vector3
    wave_offset: rl.Vector3

def chars_to_cstr(text: ptr[char]) -> cstr:
    unsafe:
        return cstr<-text

def text_buffer_ptr(text: ref[array[char, 64]]) -> ptr[char]:
    return ptr_of(ref_of(read(text)[0]))

def text_buffer_cstr(text: ref[array[char, 64]]) -> cstr:
    return chars_to_cstr(text_buffer_ptr(text))

def font_glyph(font: rl.Font, index: i32) -> rl.GlyphInfo:
    unsafe:
        return read(font.glyphs + index)

def font_rec(font: rl.Font, index: i32) -> rl.Rectangle:
    unsafe:
        return read(font.recs + index)

def text_codepoint_at(text: cstr, index: i32, byte_count: ptr[i32]) -> i32:
    unsafe:
        return rl.GetCodepoint(cstr<-(ptr[char]<-text + index), byte_count)

def wave_text_config_value(config: ptr[WaveTextConfig]) -> WaveTextConfig:
    unsafe:
        return read(config)

def wrap_hue(hue_value: f32) -> f32:
    var hue = hue_value
    while hue >= 360.0:
        hue -= 360.0
    while hue < 0.0:
        hue += 360.0
    return hue

def generate_random_color(s: f32, v: f32) -> rl.Color:
    let phi = f32<-0.618033988749895
    let seed = f32<-rl.GetRandomValue(0, 360)
    let hue = wrap_hue(seed + seed * phi)
    return rl.ColorFromHSV(hue, s, v)

def draw_text_codepoint_3d(font: rl.Font, codepoint: i32, position: rl.Vector3, font_size: f32, backface: bool, tint: rl.Color, show_letter_boundary: bool) -> void:
    let glyph_index = rl.GetGlyphIndex(font, codepoint)
    let glyph = font_glyph(font, glyph_index)
    let rec = font_rec(font, glyph_index)
    let scale = font_size / f32<-font.baseSize

    var glyph_position = position
    glyph_position.x += f32<-(glyph.offsetX - font.glyphPadding) * scale
    glyph_position.z += f32<-(glyph.offsetY - font.glyphPadding) * scale

    let src_rec = rl.Rectangle(
        x = rec.x - f32<-font.glyphPadding,
        y = rec.y - f32<-font.glyphPadding,
        width = rec.width + 2.0 * f32<-font.glyphPadding,
        height = rec.height + 2.0 * f32<-font.glyphPadding,
    )

    let width = (rec.width + 2.0 * f32<-font.glyphPadding) * scale
    let height = (rec.height + 2.0 * f32<-font.glyphPadding) * scale

    if font.texture.id > 0:
        let tx = src_rec.x / f32<-font.texture.width
        let ty = src_rec.y / f32<-font.texture.height
        let tw = (src_rec.x + src_rec.width) / f32<-font.texture.width
        let th = (src_rec.y + src_rec.height) / f32<-font.texture.height

        if show_letter_boundary:
            rl.DrawCubeWiresV(
                rl.Vector3(x = glyph_position.x + width / 2.0, y = glyph_position.y, z = glyph_position.z + height / 2.0),
                rl.Vector3(x = width, y = letter_boundary_size, z = height),
                rl.VIOLET,
            )

        rlgl.rlCheckRenderBatchLimit(4 + (if backface: 4 else: 0))
        rlgl.rlSetTexture(font.texture.id)

        rlgl.rlPushMatrix()
        rlgl.rlTranslatef(glyph_position.x, glyph_position.y, glyph_position.z)

        rlgl.rlBegin(rlgl.RL_QUADS)
        rlgl.rlColor4ub(tint.r, tint.g, tint.b, tint.a)

        rlgl.rlNormal3f(0.0, 1.0, 0.0)
        rlgl.rlTexCoord2f(tx, ty)
        rlgl.rlVertex3f(0.0, 0.0, 0.0)
        rlgl.rlTexCoord2f(tx, th)
        rlgl.rlVertex3f(0.0, 0.0, height)
        rlgl.rlTexCoord2f(tw, th)
        rlgl.rlVertex3f(width, 0.0, height)
        rlgl.rlTexCoord2f(tw, ty)
        rlgl.rlVertex3f(width, 0.0, 0.0)

        if backface:
            rlgl.rlNormal3f(0.0, -1.0, 0.0)
            rlgl.rlTexCoord2f(tx, ty)
            rlgl.rlVertex3f(0.0, 0.0, 0.0)
            rlgl.rlTexCoord2f(tw, ty)
            rlgl.rlVertex3f(width, 0.0, 0.0)
            rlgl.rlTexCoord2f(tw, th)
            rlgl.rlVertex3f(width, 0.0, height)
            rlgl.rlTexCoord2f(tx, th)
            rlgl.rlVertex3f(0.0, 0.0, height)

        rlgl.rlEnd()
        rlgl.rlPopMatrix()

        rlgl.rlSetTexture(0)

def draw_text_3d(font: rl.Font, text: cstr, position: rl.Vector3, font_size: f32, font_spacing: f32, line_spacing: f32, backface: bool, tint: rl.Color, show_letter_boundary: bool) -> void:
    let length = i32<-rl.TextLength(text)
    let scale = font_size / f32<-font.baseSize

    var text_offset_y = f32<-0.0
    var text_offset_x = f32<-0.0
    var index = 0
    while index < length:
        var codepoint_byte_count = 0
        let codepoint = text_codepoint_at(text, index, ptr_of(ref_of(codepoint_byte_count)))
        let glyph_index = rl.GetGlyphIndex(font, codepoint)
        let glyph = font_glyph(font, glyph_index)
        let rec = font_rec(font, glyph_index)

        if codepoint == 0x3f:
            codepoint_byte_count = 1

        if codepoint == 10:
            text_offset_y += font_size + line_spacing
            text_offset_x = f32<-0.0
        else:
            if codepoint != 32 and codepoint != 9:
                draw_text_codepoint_3d(
                    font,
                    codepoint,
                    rl.Vector3(x = position.x + text_offset_x, y = position.y, z = position.z + text_offset_y),
                    font_size,
                    backface,
                    tint,
                    show_letter_boundary,
                )

            if glyph.advanceX == 0:
                text_offset_x += rec.width * scale + font_spacing
            else:
                text_offset_x += f32<-glyph.advanceX * scale + font_spacing

        index += codepoint_byte_count

def draw_text_wave_3d(font: rl.Font, text: cstr, position: rl.Vector3, font_size: f32, font_spacing: f32, line_spacing: f32, backface: bool, config: ptr[WaveTextConfig], time: f32, tint: rl.Color, show_letter_boundary: bool) -> void:
    let length = i32<-rl.TextLength(text)
    let scale = font_size / f32<-font.baseSize
    let wave_config = wave_text_config_value(config)

    var text_offset_y = f32<-0.0
    var text_offset_x = f32<-0.0
    var wave = false
    var index = 0
    var glyph_position = 0
    while index < length:
        var codepoint_byte_count = 0
        let codepoint = text_codepoint_at(text, index, ptr_of(ref_of(codepoint_byte_count)))
        let glyph_index = rl.GetGlyphIndex(font, codepoint)
        let glyph = font_glyph(font, glyph_index)
        let rec = font_rec(font, glyph_index)

        if codepoint == 0x3f:
            codepoint_byte_count = 1

        if codepoint == 10:
            text_offset_y += font_size + line_spacing
            text_offset_x = f32<-0.0
            glyph_position = 0
        elif codepoint == 126:
            var next_byte_count = 0
            let next_codepoint = text_codepoint_at(text, index + 1, ptr_of(ref_of(next_byte_count)))
            if next_codepoint == 126:
                codepoint_byte_count += 1
                wave = not wave
        else:
            if codepoint != 32 and codepoint != 9:
                var glyph_origin = position
                if wave:
                    glyph_origin.x += math.sinf(time * wave_config.wave_speed.x - f32<-glyph_position * wave_config.wave_offset.x) * wave_config.wave_range.x
                    glyph_origin.y += math.sinf(time * wave_config.wave_speed.y - f32<-glyph_position * wave_config.wave_offset.y) * wave_config.wave_range.y
                    glyph_origin.z += math.sinf(time * wave_config.wave_speed.z - f32<-glyph_position * wave_config.wave_offset.z) * wave_config.wave_range.z

                draw_text_codepoint_3d(
                    font,
                    codepoint,
                    rl.Vector3(x = glyph_origin.x + text_offset_x, y = glyph_origin.y, z = glyph_origin.z + text_offset_y),
                    font_size,
                    backface,
                    tint,
                    show_letter_boundary,
                )

            if glyph.advanceX == 0:
                text_offset_x += rec.width * scale + font_spacing
            else:
                text_offset_x += f32<-glyph.advanceX * scale + font_spacing

            glyph_position += 1

        index += codepoint_byte_count

def measure_text_wave_3d(font: rl.Font, text: cstr, font_size: f32, font_spacing: f32, line_spacing: f32) -> rl.Vector3:
    let length = i32<-rl.TextLength(text)
    let scale = font_size / f32<-font.baseSize

    var temp_len = 0
    var len_counter = 0
    var temp_text_width = f32<-0.0
    var text_height = scale
    var text_width = f32<-0.0
    var index = 0
    while index < length:
        var next_bytes = 0
        let codepoint = text_codepoint_at(text, index, ptr_of(ref_of(next_bytes)))
        let glyph_index = rl.GetGlyphIndex(font, codepoint)
        let glyph = font_glyph(font, glyph_index)
        let rec = font_rec(font, glyph_index)

        if codepoint == 0x3f:
            next_bytes = 1

        if codepoint != 10:
            if codepoint == 126:
                var next_codepoint_bytes = 0
                if text_codepoint_at(text, index + 1, ptr_of(ref_of(next_codepoint_bytes))) == 126:
                    index += 1
                else:
                    len_counter += 1
                    if glyph.advanceX != 0:
                        text_width += f32<-glyph.advanceX * scale
                    else:
                        text_width += (rec.width + f32<-glyph.offsetX) * scale
            else:
                len_counter += 1
                if glyph.advanceX != 0:
                    text_width += f32<-glyph.advanceX * scale
                else:
                    text_width += (rec.width + f32<-glyph.offsetX) * scale
        else:
            if temp_text_width < text_width:
                temp_text_width = text_width
            len_counter = 0
            text_width = f32<-0.0
            text_height += font_size + line_spacing

        if temp_len < len_counter:
            temp_len = len_counter

        index += next_bytes

    if temp_text_width < text_width:
        temp_text_width = text_width

    return rl.Vector3(
        x = temp_text_width + f32<-(temp_len - 1) * font_spacing,
        y = 0.25,
        z = text_height,
    )

def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT | rl.ConfigFlags.FLAG_VSYNC_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var spin = true
    var multicolor = false
    var show_letter_boundary = false
    var show_text_boundary = false

    var camera = zero[rl.Camera3D]()
    camera.position = rl.Vector3(x = -10.0, y = 15.0, z = -10.0)
    camera.target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
    camera.up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
    camera.fovy = 45.0
    camera.projection = i32<-rl.CameraProjection.CAMERA_PERSPECTIVE

    var camera_mode = i32<-rl.CameraMode.CAMERA_ORBITAL

    let cube_position = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
    let cube_size = rl.Vector3(x = 2.0, y = 2.0, z = 2.0)

    var font = rl.GetFontDefault()
    var font_size = f32<-0.8
    var font_spacing = f32<-0.05
    var line_spacing = f32<-(-0.1)

    var text = zero[array[char, 64]]()
    rl.TextCopy(text_buffer_ptr(ref_of(text)), initial_text)

    var text_box = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
    var layers = 1
    var quads = 0
    var layer_distance = f32<-0.01

    var wave_config = WaveTextConfig(
        wave_range = rl.Vector3(x = 0.45, y = 0.45, z = 0.45),
        wave_speed = rl.Vector3(x = 3.0, y = 3.0, z = 0.5),
        wave_offset = rl.Vector3(x = 0.35, y = 0.35, z = 0.35),
    )

    var time = f32<-0.0
    var light = rl.MAROON
    var dark = rl.RED
    var alpha_discard = zero[rl.Shader]()
    alpha_discard = rl.LoadShader(null, alpha_discard_shader_path)
    defer rl.UnloadShader(alpha_discard)

    var multi = zero[array[rl.Color, 32]]()

    rl.DisableCursor()
    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(ref_of(camera)), camera_mode)

        if rl.IsFileDropped():
            let dropped_files = rl.LoadDroppedFiles()
            if dropped_files.count > 0:
                unsafe:
                    let dropped_path = cstr<-read(dropped_files.paths)
                    if rl.IsFileExtension(dropped_path, c".ttf"):
                        rl.UnloadFont(font)
                        font = rl.LoadFontEx(dropped_path, i32<-font_size, null, 0)
                    elif rl.IsFileExtension(dropped_path, c".fnt"):
                        rl.UnloadFont(font)
                        font = rl.LoadFont(dropped_path)
                        font_size = f32<-font.baseSize
            rl.UnloadDroppedFiles(dropped_files)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_F1):
            show_letter_boundary = not show_letter_boundary
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_F2):
            show_text_boundary = not show_text_boundary
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_F3):
            spin = not spin
            camera = zero[rl.Camera3D]()
            camera.target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
            camera.up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
            camera.fovy = 45.0
            camera.projection = i32<-rl.CameraProjection.CAMERA_PERSPECTIVE

            if spin:
                camera.position = rl.Vector3(x = -10.0, y = 15.0, z = -10.0)
                camera_mode = i32<-rl.CameraMode.CAMERA_ORBITAL
            else:
                camera.position = rl.Vector3(x = 10.0, y = 10.0, z = -10.0)
                camera_mode = i32<-rl.CameraMode.CAMERA_FREE

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            let ray = rl.GetScreenToWorldRay(rl.GetMousePosition(), camera)
            let collision = rl.GetRayCollisionBox(
                ray,
                rl.BoundingBox(
                    min = rl.Vector3(x = cube_position.x - cube_size.x / 2.0, y = cube_position.y - cube_size.y / 2.0, z = cube_position.z - cube_size.z / 2.0),
                    max = rl.Vector3(x = cube_position.x + cube_size.x / 2.0, y = cube_position.y + cube_size.y / 2.0, z = cube_position.z + cube_size.z / 2.0),
                ),
            )
            if collision.hit:
                light = generate_random_color(0.5, 0.78)
                dark = generate_random_color(0.4, 0.58)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_HOME):
            if layers > 1:
                layers -= 1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_END):
            if layers < text_max_layers:
                layers += 1

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
            font_size -= 0.5
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            font_size += 0.5
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_UP):
            font_spacing -= 0.1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_DOWN):
            font_spacing += 0.1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_PAGE_UP):
            line_spacing -= 0.1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_PAGE_DOWN):
            line_spacing += 0.1
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_INSERT):
            layer_distance -= 0.001
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_DELETE):
            layer_distance += 0.001
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_TAB):
            multicolor = not multicolor
            if multicolor:
                var color_index = 0
                while color_index < text_max_layers:
                    multi[color_index] = generate_random_color(0.5, 0.8)
                    multi[color_index].a = u8<-rl.GetRandomValue(0, 255)
                    color_index += 1

        let ch = rl.GetCharPressed()
        let text_len = i32<-rl.TextLength(text_buffer_cstr(ref_of(text)))
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_BACKSPACE):
            if text_len > 0:
                text[text_len - 1] = char<-0
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_ENTER):
            if text_len < 63:
                text[text_len] = char<-10
                text[text_len + 1] = char<-0
        else:
            if text_len < 63:
                text[text_len] = char<-ch
                text[text_len + 1] = char<-0

        text_box = measure_text_wave_3d(font, text_buffer_cstr(ref_of(text)), font_size, font_spacing, line_spacing)

        quads = 0
        time += rl.GetFrameTime()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode3D(camera)
        rl.DrawCubeV(cube_position, cube_size, dark)
        rl.DrawCubeWires(cube_position, 2.1, 2.1, 2.1, light)
        rl.DrawGrid(10, 2.0)

        rl.BeginShaderMode(alpha_discard)

        rlgl.rlPushMatrix()
        rlgl.rlRotatef(90.0, 1.0, 0.0, 0.0)
        rlgl.rlRotatef(90.0, 0.0, 0.0, -1.0)

        var layer_index = 0
        while layer_index < layers:
            var layer_color = light
            if multicolor:
                layer_color = multi[layer_index]
            draw_text_wave_3d(
                font,
                text_buffer_cstr(ref_of(text)),
                rl.Vector3(x = -text_box.x / 2.0, y = layer_distance * f32<-layer_index, z = -4.5),
                font_size,
                font_spacing,
                line_spacing,
                true,
                ptr_of(ref_of(wave_config)),
                time,
                layer_color,
                show_letter_boundary,
            )
            layer_index += 1

        if show_text_boundary:
            rl.DrawCubeWiresV(rl.Vector3(x = 0.0, y = 0.0, z = -4.5 + text_box.z / 2.0), text_box, dark)
        rlgl.rlPopMatrix()

        let saved_letter_boundary = show_letter_boundary
        show_letter_boundary = false

        rlgl.rlPushMatrix()
        rlgl.rlRotatef(180.0, 0.0, 1.0, 0.0)

        var position = rl.Vector3(x = 0.0, y = 0.01, z = 2.0)

        let size_opt = rl.TextFormat(c"< SIZE: %2.1f >", font_size)
        quads += i32<-rl.TextLength(size_opt)
        var measure = rl.MeasureTextEx(rl.GetFontDefault(), size_opt, 0.8, 0.1)
        position.x = -measure.x / 2.0
        draw_text_3d(rl.GetFontDefault(), size_opt, position, 0.8, 0.1, 0.0, false, rl.BLUE, false)
        position.z += 0.5 + measure.y

        let spacing_opt = rl.TextFormat(c"< SPACING: %2.1f >", font_spacing)
        quads += i32<-rl.TextLength(spacing_opt)
        measure = rl.MeasureTextEx(rl.GetFontDefault(), spacing_opt, 0.8, 0.1)
        position.x = -measure.x / 2.0
        draw_text_3d(rl.GetFontDefault(), spacing_opt, position, 0.8, 0.1, 0.0, false, rl.BLUE, false)
        position.z += 0.5 + measure.y

        let line_opt = rl.TextFormat(c"< LINE: %2.1f >", line_spacing)
        quads += i32<-rl.TextLength(line_opt)
        measure = rl.MeasureTextEx(rl.GetFontDefault(), line_opt, 0.8, 0.1)
        position.x = -measure.x / 2.0
        draw_text_3d(rl.GetFontDefault(), line_opt, position, 0.8, 0.1, 0.0, false, rl.BLUE, false)
        position.z += 0.5 + measure.y

        let lbox_opt = rl.TextFormat(c"< LBOX: %3s >", (if saved_letter_boundary: c"ON" else: c"OFF"))
        quads += i32<-rl.TextLength(lbox_opt)
        measure = rl.MeasureTextEx(rl.GetFontDefault(), lbox_opt, 0.8, 0.1)
        position.x = -measure.x / 2.0
        draw_text_3d(rl.GetFontDefault(), lbox_opt, position, 0.8, 0.1, 0.0, false, rl.RED, false)
        position.z += 0.5 + measure.y

        let tbox_opt = rl.TextFormat(c"< TBOX: %3s >", (if show_text_boundary: c"ON" else: c"OFF"))
        quads += i32<-rl.TextLength(tbox_opt)
        measure = rl.MeasureTextEx(rl.GetFontDefault(), tbox_opt, 0.8, 0.1)
        position.x = -measure.x / 2.0
        draw_text_3d(rl.GetFontDefault(), tbox_opt, position, 0.8, 0.1, 0.0, false, rl.RED, false)
        position.z += 0.5 + measure.y

        let layer_distance_opt = rl.TextFormat(c"< LAYER DISTANCE: %.3f >", layer_distance)
        quads += i32<-rl.TextLength(layer_distance_opt)
        measure = rl.MeasureTextEx(rl.GetFontDefault(), layer_distance_opt, 0.8, 0.1)
        position.x = -measure.x / 2.0
        draw_text_3d(rl.GetFontDefault(), layer_distance_opt, position, 0.8, 0.1, 0.0, false, rl.DARKPURPLE, false)

        position = rl.Vector3(x = 0.0, y = 0.01, z = 2.0)
        let info1 = c"All the text displayed here is in 3D"
        quads += 36
        measure = rl.MeasureTextEx(rl.GetFontDefault(), info1, 1.0, 0.05)
        position.x = -measure.x / 2.0
        draw_text_3d(rl.GetFontDefault(), info1, position, 1.0, 0.05, 0.0, false, rl.DARKBLUE, false)
        position.z += 1.5 + measure.y

        let info2 = c"press [Left]/[Right] to change the font size"
        quads += 44
        measure = rl.MeasureTextEx(rl.GetFontDefault(), info2, 0.6, 0.05)
        position.x = -measure.x / 2.0
        draw_text_3d(rl.GetFontDefault(), info2, position, 0.6, 0.05, 0.0, false, rl.DARKBLUE, false)
        position.z += 0.5 + measure.y

        let info3 = c"press [Up]/[Down] to change the font spacing"
        quads += 44
        measure = rl.MeasureTextEx(rl.GetFontDefault(), info3, 0.6, 0.05)
        position.x = -measure.x / 2.0
        draw_text_3d(rl.GetFontDefault(), info3, position, 0.6, 0.05, 0.0, false, rl.DARKBLUE, false)
        position.z += 0.5 + measure.y

        let info4 = c"press [PgUp]/[PgDown] to change the line spacing"
        quads += 48
        measure = rl.MeasureTextEx(rl.GetFontDefault(), info4, 0.6, 0.05)
        position.x = -measure.x / 2.0
        draw_text_3d(rl.GetFontDefault(), info4, position, 0.6, 0.05, 0.0, false, rl.DARKBLUE, false)
        position.z += 0.5 + measure.y

        let info5 = c"press [F1] to toggle the letter boundry"
        quads += 39
        measure = rl.MeasureTextEx(rl.GetFontDefault(), info5, 0.6, 0.05)
        position.x = -measure.x / 2.0
        draw_text_3d(rl.GetFontDefault(), info5, position, 0.6, 0.05, 0.0, false, rl.DARKBLUE, false)
        position.z += 0.5 + measure.y

        let info6 = c"press [F2] to toggle the text boundry"
        quads += 37
        measure = rl.MeasureTextEx(rl.GetFontDefault(), info6, 0.6, 0.05)
        position.x = -measure.x / 2.0
        draw_text_3d(rl.GetFontDefault(), info6, position, 0.6, 0.05, 0.0, false, rl.DARKBLUE, false)

        rlgl.rlPopMatrix()
        show_letter_boundary = saved_letter_boundary

        rl.EndShaderMode()
        rl.EndMode3D()

        rl.DrawText(c"Drag & drop a font file to change the font!\nType something, see what happens!\n\nPress [F3] to toggle the camera", 10, 35, 10, rl.BLACK)

        quads += i32<-rl.TextLength(text_buffer_cstr(ref_of(text))) * 2 * layers
        let stats = rl.TextFormat(c"%2i layer(s) | %s camera | %4i quads (%4i verts)", layers, (if spin: c"ORBITAL" else: c"FREE"), quads, quads * 4)
        var width = rl.MeasureText(stats, 10)
        rl.DrawText(stats, screen_width - 20 - width, 10, 10, rl.DARKGREEN)

        let hint1 = c"[Home]/[End] to add/remove 3D text layers"
        width = rl.MeasureText(hint1, 10)
        rl.DrawText(hint1, screen_width - 20 - width, 25, 10, rl.DARKGRAY)

        let hint2 = c"[Insert]/[Delete] to increase/decrease distance between layers"
        width = rl.MeasureText(hint2, 10)
        rl.DrawText(hint2, screen_width - 20 - width, 40, 10, rl.DARKGRAY)

        let hint3 = c"click the [CUBE] for a random color"
        width = rl.MeasureText(hint3, 10)
        rl.DrawText(hint3, screen_width - 20 - width, 55, 10, rl.DARKGRAY)

        let hint4 = c"[Tab] to toggle multicolor mode"
        width = rl.MeasureText(hint4, 10)
        rl.DrawText(hint4, screen_width - 20 - width, 70, 10, rl.DARKGRAY)

        rl.DrawFPS(10, 10)

    rl.UnloadFont(font)
    return 0