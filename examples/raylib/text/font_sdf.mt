import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [text] example - font sdf")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let msg = "Signed Distance Fields"

    var file_size = 0
    let file_data = rl.load_file_data("anonymous_pro_bold.ttf", file_size) else:
        fatal("could not load anonymous_pro_bold.ttf")
    defer rl.unload_file_data(file_data)

    var font_default = zero[rl.Font]
    font_default.baseSize = 16
    font_default.glyphCount = 95
    font_default.glyphs = rl.load_font_data(file_data, file_size, 16, null, 95, rl.FontType.FONT_DEFAULT, font_default.glyphCount)
    var atlas = rl.gen_image_font_atlas(font_default.glyphs, font_default.recs, 95, 16, 4, 0)
    font_default.texture = rl.load_texture_from_image(atlas)
    rl.unload_image(atlas)

    var font_sdf = zero[rl.Font]
    font_sdf.baseSize = 16
    font_sdf.glyphCount = 95
    font_sdf.glyphs = rl.load_font_data(file_data, file_size, 16, null, 0, rl.FontType.FONT_SDF, font_sdf.glyphCount)
    atlas = rl.gen_image_font_atlas(font_sdf.glyphs, font_sdf.recs, 95, 16, 0, 1)
    font_sdf.texture = rl.load_texture_from_image(atlas)
    rl.unload_image(atlas)

    defer rl.unload_font(font_default)
    defer rl.unload_font(font_sdf)

    let shader_path = rl.text_format("shaders/glsl%i/sdf.fs", GLSL_VERSION)
    let shader = rl.load_shader(null, shader_path)
    defer rl.unload_shader(shader)
    rl.set_texture_filter(font_sdf.texture, int<-rl.TextureFilter.TEXTURE_FILTER_BILINEAR)

    var font_position = rl.Vector2(x = 40.0, y = float<-SCREEN_HEIGHT / 2.0 - 50.0)
    var text_size = rl.Vector2(x = 0.0, y = 0.0)
    var font_size = float<-16.0
    var current_font = 0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        font_size += float<-(rl.get_mouse_wheel_move() * 8.0)
        if font_size < 6.0:
            font_size = 6.0

        if rl.is_key_down(rl.KeyboardKey.KEY_SPACE):
            current_font = 1
        else:
            current_font = 0

        if current_font == 0:
            text_size = rl.measure_text_ex(font_default, msg, font_size, 0.0)
        else:
            text_size = rl.measure_text_ex(font_sdf, msg, font_size, 0.0)

        font_position.x = float<-rl.get_screen_width() / 2.0 - text_size.x / 2.0
        font_position.y = float<-rl.get_screen_height() / 2.0 - text_size.y / 2.0 + 80.0

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        if current_font == 1:
            rl.begin_shader_mode(shader)
            rl.draw_text_ex(font_sdf, msg, font_position, font_size, 0.0, rl.BLACK)
            rl.end_shader_mode()
            rl.draw_texture(font_sdf.texture, 10, 10, rl.BLACK)
        else:
            rl.draw_text_ex(font_default, msg, font_position, font_size, 0.0, rl.BLACK)
            rl.draw_texture(font_default.texture, 10, 10, rl.BLACK)

        if current_font == 1:
            rl.draw_text("SDF!", 320, 20, 80, rl.RED)
        else:
            rl.draw_text("default font", 315, 40, 30, rl.GRAY)

        let render_size_text = rl.text_format("RENDER SIZE: %02.02f", font_size)
        rl.draw_text("FONT SIZE: 16.0", rl.get_screen_width() - 240, 20, 20, rl.DARKGRAY)
        rl.draw_text(render_size_text, rl.get_screen_width() - 240, 50, 20, rl.DARKGRAY)
        rl.draw_text("Use MOUSE WHEEL to SCALE TEXT!", rl.get_screen_width() - 240, 90, 10, rl.DARKGRAY)
        rl.draw_text("HOLD SPACE to USE SDF FONT VERSION!", 340, rl.get_screen_height() - 30, 20, rl.MAROON)

        rl.end_drawing()

    return 0
