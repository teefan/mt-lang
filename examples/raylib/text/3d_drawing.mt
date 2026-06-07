import std.math as math
import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.rlgl as rlgl
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330
const LETTER_BOUNDARY_SIZE: float = 0.25
const TEXT_MAX_LAYERS: int = 32
const TEXT_BUFFER_CAPACITY: int = 64

var show_letter_boundary: bool = false
var show_text_boundary: bool = false

struct WaveTextConfig:
    wave_range: rl.Vector3
    wave_speed: rl.Vector3
    wave_offset: rl.Vector3


function buffer_as_str(buffer: ref[array[char, TEXT_BUFFER_CAPACITY]]) -> str:
    return text.chars_as_str(ptr_of(read(buffer)[0]))


function draw_text_codepoint_3d(
    font: rl.Font,
    codepoint: int,
    position: rl.Vector3,
    font_size: float,
    backface: bool,
    tint: rl.Color
) -> void:
    let glyph_index = rl.get_glyph_index(font, codepoint)
    let scale = font_size / float<-font.baseSize

    var glyph_offset_x = 0
    var glyph_offset_y = 0
    let glyph_padding = font.glyphPadding
    var rec = rl.Rectangle(x = 0.0, y = 0.0, width = 0.0, height = 0.0)
    unsafe:
        glyph_offset_x = read(font.glyphs + ptr_uint<-glyph_index).offsetX
        glyph_offset_y = read(font.glyphs + ptr_uint<-glyph_index).offsetY
        rec = read(font.recs + ptr_uint<-glyph_index)

    var glyph_position = position
    glyph_position.x += float<-(glyph_offset_x - glyph_padding) * scale
    glyph_position.z += float<-(glyph_offset_y - glyph_padding) * scale

    let src_rec = rl.Rectangle(
        x = rec.x - float<-glyph_padding,
        y = rec.y - float<-glyph_padding,
        width = rec.width + 2.0 * float<-glyph_padding,
        height = rec.height + 2.0 * float<-glyph_padding
    )

    let width = (rec.width + 2.0 * float<-glyph_padding) * scale
    let height = (rec.height + 2.0 * float<-glyph_padding) * scale

    if font.texture.id > 0:
        let tx = src_rec.x / float<-font.texture.width
        let ty = src_rec.y / float<-font.texture.height
        let tw = (src_rec.x + src_rec.width) / float<-font.texture.width
        let th = (src_rec.y + src_rec.height) / float<-font.texture.height

        if show_letter_boundary:
            rl.draw_cube_wires_v(
                rl.Vector3(
                    x = glyph_position.x + width / 2.0,
                    y = glyph_position.y,
                    z = glyph_position.z + height / 2.0
                ),
                rl.Vector3(x = width, y = LETTER_BOUNDARY_SIZE, z = height),
                rl.VIOLET
            )

        let vertex_quad_count = if backface: 8 else: 4
        rlgl.check_render_batch_limit(vertex_quad_count)
        rlgl.set_texture(font.texture.id)

        rlgl.push_matrix()
        rlgl.translatef(glyph_position.x, glyph_position.y, glyph_position.z)

        rlgl.begin(rlgl.RL_QUADS)
        rlgl.color4ub(tint.r, tint.g, tint.b, tint.a)

        rlgl.normal3f(0.0, 1.0, 0.0)
        rlgl.tex_coord2f(tx, ty)
        rlgl.vertex3f(0.0, 0.0, 0.0)
        rlgl.tex_coord2f(tx, th)
        rlgl.vertex3f(0.0, 0.0, height)
        rlgl.tex_coord2f(tw, th)
        rlgl.vertex3f(width, 0.0, height)
        rlgl.tex_coord2f(tw, ty)
        rlgl.vertex3f(width, 0.0, 0.0)

        if backface:
            rlgl.normal3f(0.0, -1.0, 0.0)
            rlgl.tex_coord2f(tx, ty)
            rlgl.vertex3f(0.0, 0.0, 0.0)
            rlgl.tex_coord2f(tw, ty)
            rlgl.vertex3f(width, 0.0, 0.0)
            rlgl.tex_coord2f(tw, th)
            rlgl.vertex3f(width, 0.0, height)
            rlgl.tex_coord2f(tx, th)
            rlgl.vertex3f(0.0, 0.0, height)

        rlgl.end()
        rlgl.pop_matrix()
        rlgl.set_texture(0)


function draw_text_3d(
    font: rl.Font,
    body_text: str,
    position: rl.Vector3,
    font_size: float,
    font_spacing: float,
    line_spacing: float,
    backface: bool,
    tint: rl.Color
) -> void:
    let length = int<-rl.text_length(body_text)
    let scale = font_size / float<-font.baseSize
    var text_offset_x = float<-0.0
    var text_offset_y = float<-0.0
    var index = 0

    while index < length:
        var codepoint_byte_count = 0
        let codepoint = rl.get_codepoint(
            body_text.slice(ptr_uint<-index, ptr_uint<-(length - index)),
            codepoint_byte_count
        )
        var advance = codepoint_byte_count
        if codepoint == 0x3f:
            advance = 1

        let glyph_index = rl.get_glyph_index(font, codepoint)
        var glyph_advance_x = 0
        var rec_width = float<-0.0
        unsafe:
            glyph_advance_x = read(font.glyphs + ptr_uint<-glyph_index).advanceX
            rec_width = read(font.recs + ptr_uint<-glyph_index).width

        if codepoint == 10:
            text_offset_y += font_size + line_spacing
            text_offset_x = 0.0
        else:
            if codepoint != 32 and codepoint != 9:
                draw_text_codepoint_3d(
                    font,
                    codepoint,
                    rl.Vector3(x = position.x + text_offset_x, y = position.y, z = position.z + text_offset_y),
                    font_size,
                    backface,
                    tint
                )

            if glyph_advance_x == 0:
                text_offset_x += rec_width * scale + font_spacing
            else:
                text_offset_x += float<-glyph_advance_x * scale + font_spacing

        index += advance


function draw_text_wave_3d(
    font: rl.Font,
    body_text: str,
    position: rl.Vector3,
    font_size: float,
    font_spacing: float,
    line_spacing: float,
    backface: bool,
    config: WaveTextConfig,
    time_value: float,
    tint: rl.Color
) -> void:
    let length = int<-rl.text_length(body_text)
    let scale = font_size / float<-font.baseSize
    var text_offset_x = float<-0.0
    var text_offset_y = float<-0.0
    var wave = false
    var char_index = 0
    var index = 0

    while index < length:
        var codepoint_byte_count = 0
        let codepoint = rl.get_codepoint(
            body_text.slice(ptr_uint<-index, ptr_uint<-(length - index)),
            codepoint_byte_count
        )
        var advance = codepoint_byte_count
        if codepoint == 0x3f:
            advance = 1

        let glyph_index = rl.get_glyph_index(font, codepoint)
        var glyph_advance_x = 0
        var rec_width = float<-0.0
        unsafe:
            glyph_advance_x = read(font.glyphs + ptr_uint<-glyph_index).advanceX
            rec_width = read(font.recs + ptr_uint<-glyph_index).width

        if codepoint == 10:
            text_offset_y += font_size + line_spacing
            text_offset_x = 0.0
            char_index = 0
        else if codepoint == 126 and index + 1 < length:
            var next_size = 0
            let next_codepoint = rl.get_codepoint(
                body_text.slice(ptr_uint<-(index + 1), ptr_uint<-(length - index - 1)),
                next_size
            )
            if next_codepoint == 126:
                wave = not wave
                advance += 1
        else:
            if codepoint != 32 and codepoint != 9:
                var glyph_position = position
                if wave:
                    glyph_position.x += float<-math.sin(double<-(time_value * config.wave_speed.x - float<-char_index * config.wave_offset.x)) * config.wave_range.x
                    glyph_position.y += float<-math.sin(double<-(time_value * config.wave_speed.y - float<-char_index * config.wave_offset.y)) * config.wave_range.y
                    glyph_position.z += float<-math.sin(double<-(time_value * config.wave_speed.z - float<-char_index * config.wave_offset.z)) * config.wave_range.z

                draw_text_codepoint_3d(
                    font,
                    codepoint,
                    rl.Vector3(
                        x = glyph_position.x + text_offset_x,
                        y = glyph_position.y,
                        z = glyph_position.z + text_offset_y
                    ),
                    font_size,
                    backface,
                    tint
                )

            if glyph_advance_x == 0:
                text_offset_x += rec_width * scale + font_spacing
            else:
                text_offset_x += float<-glyph_advance_x * scale + font_spacing
            char_index += 1

        index += advance


function measure_text_wave_3d(
    font: rl.Font,
    body_text: str,
    font_size: float,
    font_spacing: float,
    line_spacing: float
) -> rl.Vector3:
    let length = int<-rl.text_length(body_text)
    let scale = font_size / float<-font.baseSize
    var temp_len = 0
    var len_counter = 0
    var temp_text_width = float<-0.0
    var text_height = scale
    var text_width = float<-0.0
    var index = 0

    while index < length:
        var codepoint_byte_count = 0
        let codepoint = rl.get_codepoint(
            body_text.slice(ptr_uint<-index, ptr_uint<-(length - index)),
            codepoint_byte_count
        )
        var advance = codepoint_byte_count
        if codepoint == 0x3f:
            advance = 1

        let glyph_index = rl.get_glyph_index(font, codepoint)
        var glyph_advance_x = 0
        var rec_width = float<-0.0
        var glyph_offset_x = 0
        unsafe:
            glyph_advance_x = read(font.glyphs + ptr_uint<-glyph_index).advanceX
            rec_width = read(font.recs + ptr_uint<-glyph_index).width
            glyph_offset_x = read(font.glyphs + ptr_uint<-glyph_index).offsetX

        if codepoint != 10:
            if codepoint == 126 and index + 1 < length:
                var next_size = 0
                let next_codepoint = rl.get_codepoint(
                    body_text.slice(ptr_uint<-(index + 1), ptr_uint<-(length - index - 1)),
                    next_size
                )
                if next_codepoint == 126:
                    index += 2
                    continue

            len_counter += 1
            if glyph_advance_x != 0:
                text_width += float<-glyph_advance_x * scale
            else:
                text_width += (rec_width + float<-glyph_offset_x) * scale
        else:
            if temp_text_width < text_width:
                temp_text_width = text_width
            len_counter = 0
            text_width = 0.0
            text_height += font_size + line_spacing

        if temp_len < len_counter:
            temp_len = len_counter

        index += advance

    if temp_text_width < text_width:
        temp_text_width = text_width

    return rl.Vector3(x = temp_text_width + float<-(temp_len - 1) * font_spacing, y = 0.25, z = text_height)


function generate_random_color(saturation: float, value: float) -> rl.Color:
    let phi = 0.618033988749895
    var hue = float<-rl.get_random_value(0, 360)
    hue = float<-math.mod(double<-(hue + hue * float<-phi), 360.0)
    return rl.color_from_hsv(hue, saturation, value)


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT | rl.ConfigFlags.FLAG_VSYNC_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [text] example - 3d drawing")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var spin = true
    var multicolor = false

    var camera = zero[rl.Camera3D]
    camera.position = rl.Vector3(x = -10.0, y = 15.0, z = -10.0)
    camera.target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
    camera.up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
    camera.fovy = 45.0
    camera.projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    var camera_mode = rl.CameraMode.CAMERA_ORBITAL

    let cube_position = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
    let cube_size = rl.Vector3(x = 2.0, y = 2.0, z = 2.0)

    var font = rl.get_font_default()
    var owns_font = false
    var font_size = float<-0.8
    var font_spacing = float<-0.05
    var line_spacing = float<-(-0.1)

    var text_buffer: array[char, TEXT_BUFFER_CAPACITY] = zero[array[char, TEXT_BUFFER_CAPACITY]]
    rl.text_copy(ptr_of(text_buffer[0]), "Hello ~~World~~ in 3D!")

    var text_box = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
    var layers = 1
    var quads = 0
    var layer_distance = float<-0.01
    let wave_config = WaveTextConfig(
        wave_range = rl.Vector3(x = 0.45, y = 0.45, z = 0.45),
        wave_speed = rl.Vector3(x = 3.0, y = 3.0, z = 0.5),
        wave_offset = rl.Vector3(x = 0.35, y = 0.35, z = 0.35)
    )
    var time_value = float<-0.0
    var light = rl.MAROON
    var dark = rl.RED

    let alpha_discard_path = rl.text_format("shaders/glsl%i/alpha_discard.fs", GLSL_VERSION)
    let alpha_discard = rl.load_shader(null, alpha_discard_path)
    defer rl.unload_shader(alpha_discard)

    var multi: array[rl.Color, TEXT_MAX_LAYERS] = zero[array[rl.Color, TEXT_MAX_LAYERS]]

    rl.disable_cursor()
    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, camera_mode)

        if rl.is_file_dropped():
            let dropped_files = rl.load_dropped_files()
            defer rl.unload_dropped_files(dropped_files)
            if dropped_files.count > uint<-0:
                let dropped_path = unsafe: text.chars_as_str(read(dropped_files.paths))
                if rl.is_file_extension(dropped_path, ".ttf"):
                    if owns_font:
                        rl.unload_font(font)
                    font = rl.load_font_ex(dropped_path, int<-(font_size * 10.0), null, 0)
                    owns_font = true
                else if rl.is_file_extension(dropped_path, ".fnt"):
                    if owns_font:
                        rl.unload_font(font)
                    font = rl.load_font(dropped_path)
                    font_size = float<-font.baseSize
                    owns_font = true

        if rl.is_key_pressed(rl.KeyboardKey.KEY_F1):
            show_letter_boundary = not show_letter_boundary
        if rl.is_key_pressed(rl.KeyboardKey.KEY_F2):
            show_text_boundary = not show_text_boundary
        if rl.is_key_pressed(rl.KeyboardKey.KEY_F3):
            spin = not spin
            camera = zero[rl.Camera3D]
            camera.target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
            camera.up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
            camera.fovy = 45.0
            camera.projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
            if spin:
                camera.position = rl.Vector3(x = -10.0, y = 15.0, z = -10.0)
                camera_mode = rl.CameraMode.CAMERA_ORBITAL
            else:
                camera.position = rl.Vector3(x = 10.0, y = 10.0, z = -10.0)
                camera_mode = rl.CameraMode.CAMERA_FREE

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            let ray = rl.get_screen_to_world_ray(rl.get_mouse_position(), camera)
            let collision = rl.get_ray_collision_box(
                ray,
                rl.BoundingBox(
                    min = rl.Vector3(
                        x = cube_position.x - cube_size.x / 2.0,
                        y = cube_position.y - cube_size.y / 2.0,
                        z = cube_position.z - cube_size.z / 2.0
                    ),
                    max = rl.Vector3(
                        x = cube_position.x + cube_size.x / 2.0,
                        y = cube_position.y + cube_size.y / 2.0,
                        z = cube_position.z + cube_size.z / 2.0
                    )
                )
            )
            if collision.hit:
                light = generate_random_color(0.5, 0.78)
                dark = generate_random_color(0.4, 0.58)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_HOME) and layers > 1:
            layers -= 1
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_END) and layers < TEXT_MAX_LAYERS:
            layers += 1

        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            font_size -= 0.5
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            font_size += 0.5
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            font_spacing -= 0.1
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            font_spacing += 0.1
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_PAGE_UP):
            line_spacing -= 0.1
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_PAGE_DOWN):
            line_spacing += 0.1
        else if rl.is_key_down(rl.KeyboardKey.KEY_INSERT):
            layer_distance -= 0.001
        else if rl.is_key_down(rl.KeyboardKey.KEY_DELETE):
            layer_distance += 0.001
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_TAB):
            multicolor = not multicolor
            if multicolor:
                var color_index = 0
                while color_index < TEXT_MAX_LAYERS:
                    multi[color_index] = generate_random_color(0.5, 0.8)
                    multi[color_index].a = ubyte<-rl.get_random_value(0, 255)
                    color_index += 1

        let rendered_text = buffer_as_str(ref_of(text_buffer))
        let text_len = int<-rl.text_length(rendered_text)
        let char_pressed = rl.get_char_pressed()
        if rl.is_key_pressed(rl.KeyboardKey.KEY_BACKSPACE):
            if text_len > 0:
                text_buffer[text_len - 1] = zero[char]
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_ENTER):
            if text_len < TEXT_BUFFER_CAPACITY - 1:
                text_buffer[text_len] = char<-10
                text_buffer[text_len + 1] = zero[char]
        else if char_pressed > 0 and text_len < TEXT_BUFFER_CAPACITY - 1:
            text_buffer[text_len] = char<-char_pressed
            text_buffer[text_len + 1] = zero[char]

        let live_text = buffer_as_str(ref_of(text_buffer))
        text_box = measure_text_wave_3d(font, live_text, font_size, font_spacing, line_spacing)

        quads = 0
        time_value += rl.get_frame_time()

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_cube_v(cube_position, cube_size, dark)
        rl.draw_cube_wires(cube_position, 2.1, 2.1, 2.1, light)
        rl.draw_grid(10, 2.0)

        rl.begin_shader_mode(alpha_discard)
        rlgl.push_matrix()
        rlgl.rotatef(90.0, 1.0, 0.0, 0.0)
        rlgl.rotatef(90.0, 0.0, 0.0, -1.0)

        var layer_index = 0
        while layer_index < layers:
            var tint = light
            if multicolor:
                tint = multi[layer_index]
            draw_text_wave_3d(
                font,
                live_text,
                rl.Vector3(x = -text_box.x / 2.0, y = layer_distance * float<-layer_index, z = -4.5),
                font_size,
                font_spacing,
                line_spacing,
                true,
                wave_config,
                time_value,
                tint
            )
            layer_index += 1

        if show_text_boundary:
            rl.draw_cube_wires_v(rl.Vector3(x = 0.0, y = 0.0, z = -4.5 + text_box.z / 2.0), text_box, dark)

        rlgl.pop_matrix()

        let saved_letter_boundary = show_letter_boundary
        show_letter_boundary = false

        rlgl.push_matrix()
        rlgl.rotatef(180.0, 0.0, 1.0, 0.0)

        var pos = rl.Vector3(x = 0.0, y = 0.01, z = 2.0)
        var opt = text.cstr_as_str(rl.text_format("< SIZE: %2.1f >", font_size))
        quads += int<-rl.text_length(opt)
        var metrics = rl.measure_text_ex(rl.get_font_default(), opt, 0.8, 0.1)
        pos.x = -metrics.x / 2.0
        draw_text_3d(rl.get_font_default(), opt, pos, 0.8, 0.1, 0.0, false, rl.BLUE)
        pos.z += 0.5 + metrics.y

        opt = text.cstr_as_str(rl.text_format("< SPACING: %2.1f >", font_spacing))
        quads += int<-rl.text_length(opt)
        metrics = rl.measure_text_ex(rl.get_font_default(), opt, 0.8, 0.1)
        pos.x = -metrics.x / 2.0
        draw_text_3d(rl.get_font_default(), opt, pos, 0.8, 0.1, 0.0, false, rl.BLUE)
        pos.z += 0.5 + metrics.y

        opt = text.cstr_as_str(rl.text_format("< LINE: %2.1f >", line_spacing))
        quads += int<-rl.text_length(opt)
        metrics = rl.measure_text_ex(rl.get_font_default(), opt, 0.8, 0.1)
        pos.x = -metrics.x / 2.0
        draw_text_3d(rl.get_font_default(), opt, pos, 0.8, 0.1, 0.0, false, rl.BLUE)
        pos.z += 0.5 + metrics.y

        opt = text.cstr_as_str(rl.text_format("< LBOX: %3s >", if saved_letter_boundary: "ON" else: "OFF"))
        quads += int<-rl.text_length(opt)
        metrics = rl.measure_text_ex(rl.get_font_default(), opt, 0.8, 0.1)
        pos.x = -metrics.x / 2.0
        draw_text_3d(rl.get_font_default(), opt, pos, 0.8, 0.1, 0.0, false, rl.RED)
        pos.z += 0.5 + metrics.y

        opt = text.cstr_as_str(rl.text_format("< TBOX: %3s >", if show_text_boundary: "ON" else: "OFF"))
        quads += int<-rl.text_length(opt)
        metrics = rl.measure_text_ex(rl.get_font_default(), opt, 0.8, 0.1)
        pos.x = -metrics.x / 2.0
        draw_text_3d(rl.get_font_default(), opt, pos, 0.8, 0.1, 0.0, false, rl.RED)
        pos.z += 0.5 + metrics.y

        opt = text.cstr_as_str(rl.text_format("< LAYER DISTANCE: %.3f >", layer_distance))
        quads += int<-rl.text_length(opt)
        metrics = rl.measure_text_ex(rl.get_font_default(), opt, 0.8, 0.1)
        pos.x = -metrics.x / 2.0
        draw_text_3d(rl.get_font_default(), opt, pos, 0.8, 0.1, 0.0, false, rl.DARKPURPLE)
        rlgl.pop_matrix()

        let info1 = "All the text displayed here is in 3D"
        quads += 36
        metrics = rl.measure_text_ex(rl.get_font_default(), info1, 1.0, 0.05)
        pos = rl.Vector3(x = -metrics.x / 2.0, y = 0.01, z = 2.0)
        draw_text_3d(rl.get_font_default(), info1, pos, 1.0, 0.05, 0.0, false, rl.DARKBLUE)
        pos.z += 1.5 + metrics.y

        let info2 = "press [Left]/[Right] to change the font size"
        quads += 44
        metrics = rl.measure_text_ex(rl.get_font_default(), info2, 0.6, 0.05)
        pos.x = -metrics.x / 2.0
        draw_text_3d(rl.get_font_default(), info2, pos, 0.6, 0.05, 0.0, false, rl.DARKBLUE)
        pos.z += 0.5 + metrics.y

        let info3 = "press [Up]/[Down] to change the font spacing"
        quads += 44
        metrics = rl.measure_text_ex(rl.get_font_default(), info3, 0.6, 0.05)
        pos.x = -metrics.x / 2.0
        draw_text_3d(rl.get_font_default(), info3, pos, 0.6, 0.05, 0.0, false, rl.DARKBLUE)
        pos.z += 0.5 + metrics.y

        let info4 = "press [PgUp]/[PgDown] to change the line spacing"
        quads += 48
        metrics = rl.measure_text_ex(rl.get_font_default(), info4, 0.6, 0.05)
        pos.x = -metrics.x / 2.0
        draw_text_3d(rl.get_font_default(), info4, pos, 0.6, 0.05, 0.0, false, rl.DARKBLUE)
        pos.z += 0.5 + metrics.y

        let info5 = "press [F1] to toggle the letter boundry"
        quads += 39
        metrics = rl.measure_text_ex(rl.get_font_default(), info5, 0.6, 0.05)
        pos.x = -metrics.x / 2.0
        draw_text_3d(rl.get_font_default(), info5, pos, 0.6, 0.05, 0.0, false, rl.DARKBLUE)
        pos.z += 0.5 + metrics.y

        let info6 = "press [F2] to toggle the text boundry"
        quads += 37
        metrics = rl.measure_text_ex(rl.get_font_default(), info6, 0.6, 0.05)
        pos.x = -metrics.x / 2.0
        draw_text_3d(rl.get_font_default(), info6, pos, 0.6, 0.05, 0.0, false, rl.DARKBLUE)

        show_letter_boundary = saved_letter_boundary
        rl.end_shader_mode()
        rl.end_mode_3d()

        rl.draw_text(
            "Drag & drop a font file to change the font!\nType something, see what happens!\n\nPress [F3] to toggle the camera",
            10,
            35,
            10,
            rl.BLACK
        )

        quads += int<-rl.text_length(live_text) * 2 * layers
        var hud = text.cstr_as_str(
            rl.text_format(
                "%2i layer(s) | %s camera | %4i quads (%4i verts)",
                layers,
                if spin: "ORBITAL" else: "FREE",
                quads,
                quads * 4
            )
        )
        var hud_width = rl.measure_text(hud, 10)
        rl.draw_text(hud, SCREEN_WIDTH - 20 - hud_width, 10, 10, rl.DARKGREEN)

        hud = "[Home]/[End] to add/remove 3D text layers"
        hud_width = rl.measure_text(hud, 10)
        rl.draw_text(hud, SCREEN_WIDTH - 20 - hud_width, 25, 10, rl.DARKGRAY)
        hud = "[Insert]/[Delete] to increase/decrease distance between layers"
        hud_width = rl.measure_text(hud, 10)
        rl.draw_text(hud, SCREEN_WIDTH - 20 - hud_width, 40, 10, rl.DARKGRAY)
        hud = "click the [CUBE] for a random color"
        hud_width = rl.measure_text(hud, 10)
        rl.draw_text(hud, SCREEN_WIDTH - 20 - hud_width, 55, 10, rl.DARKGRAY)
        hud = "[Tab] to toggle multicolor mode"
        hud_width = rl.measure_text(hud, 10)
        rl.draw_text(hud, SCREEN_WIDTH - 20 - hud_width, 70, 10, rl.DARKGRAY)

        rl.draw_fps(10, 10)
        rl.end_drawing()

    if owns_font:
        rl.unload_font(font)

    return 0
