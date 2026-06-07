import std.mem.heap as heap
import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function add_codepoint_range(font: ref[rl.Font], font_path: str, start: int, stop: int) -> void:
    let range_size = stop - start + 1
    let current_range_size = read(font).glyphCount
    let updated_codepoint_count = current_range_size + range_size
    let updated_codepoints = heap.must_alloc_zeroed[int](ptr_uint<-updated_codepoint_count)
    defer heap.release(updated_codepoints)

    var index = 0
    while index < current_range_size:
        unsafe:
            read(updated_codepoints + ptr_uint<-index) = read(read(font).glyphs + ptr_uint<-index).value
        index += 1

    index = current_range_size
    while index < updated_codepoint_count:
        unsafe:
            read(updated_codepoints + ptr_uint<-index) = start + (index - current_range_size)
        index += 1

    rl.unload_font(read(font))
    unsafe: read(font) = rl.load_font_ex(font_path, 32, updated_codepoints, updated_codepoint_count)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [text] example - unicode ranges")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var font = rl.load_font("NotoSansTC-Regular.ttf")
    defer rl.unload_font(font)
    rl.set_texture_filter(font.texture, int<-rl.TextureFilter.TEXTURE_FILTER_BILINEAR)

    var unicode_range = 0
    var prev_unicode_range = 0
    var generated_this_frame = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        generated_this_frame = false

        if unicode_range != prev_unicode_range:
            generated_this_frame = true
            rl.unload_font(font)
            font = rl.load_font("NotoSansTC-Regular.ttf")

            if unicode_range >= 1:
                add_codepoint_range(ref_of(font), "NotoSansTC-Regular.ttf", 0xc0, 0x17f)
                add_codepoint_range(ref_of(font), "NotoSansTC-Regular.ttf", 0x180, 0x24f)
            if unicode_range >= 2:
                add_codepoint_range(ref_of(font), "NotoSansTC-Regular.ttf", 0x370, 0x3ff)
                add_codepoint_range(ref_of(font), "NotoSansTC-Regular.ttf", 0x1f00, 0x1fff)
            if unicode_range >= 3:
                add_codepoint_range(ref_of(font), "NotoSansTC-Regular.ttf", 0x400, 0x4ff)
                add_codepoint_range(ref_of(font), "NotoSansTC-Regular.ttf", 0x500, 0x52f)
                add_codepoint_range(ref_of(font), "NotoSansTC-Regular.ttf", 0x2de0, 0x2dff)
                add_codepoint_range(ref_of(font), "NotoSansTC-Regular.ttf", 0xa640, 0xa69f)
            if unicode_range >= 4:
                add_codepoint_range(ref_of(font), "NotoSansTC-Regular.ttf", 0x4e00, 0x9fff)
                add_codepoint_range(ref_of(font), "NotoSansTC-Regular.ttf", 0x3400, 0x4dbf)
                add_codepoint_range(ref_of(font), "NotoSansTC-Regular.ttf", 0x3000, 0x303f)
                add_codepoint_range(ref_of(font), "NotoSansTC-Regular.ttf", 0x3040, 0x309f)
                add_codepoint_range(ref_of(font), "NotoSansTC-Regular.ttf", 0x30a0, 0x30ff)
                add_codepoint_range(ref_of(font), "NotoSansTC-Regular.ttf", 0x31f0, 0x31ff)
                add_codepoint_range(ref_of(font), "NotoSansTC-Regular.ttf", 0xff00, 0xffef)
                add_codepoint_range(ref_of(font), "NotoSansTC-Regular.ttf", 0xac00, 0xd7af)
                add_codepoint_range(ref_of(font), "NotoSansTC-Regular.ttf", 0x1100, 0x11ff)

            prev_unicode_range = unicode_range
            rl.set_texture_filter(font.texture, int<-rl.TextureFilter.TEXTURE_FILTER_BILINEAR)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ZERO):
            unicode_range = 0
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            unicode_range = 1
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            unicode_range = 2
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            unicode_range = 3
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_FOUR):
            unicode_range = 4

        let atlas_scale = 380.0 / float<-font.texture.width

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_text("ADD CODEPOINTS: [1][2][3][4]", 20, 20, 20, rl.MAROON)
        rl.draw_text_ex(font, "> English: Hello World!", rl.Vector2(x = 50.0, y = 70.0), 32.0, 1.0, rl.DARKGRAY)
        rl.draw_text_ex(font, "> Español: Hola mundo!", rl.Vector2(x = 50.0, y = 120.0), 32.0, 1.0, rl.DARKGRAY)
        rl.draw_text_ex(font, "> Ελληνικά: Γειά σου κόσμε!", rl.Vector2(x = 50.0, y = 170.0), 32.0, 1.0, rl.DARKGRAY)
        rl.draw_text_ex(font, "> Русский: Привет мир!", rl.Vector2(x = 50.0, y = 220.0), 32.0, 0.0, rl.DARKGRAY)
        rl.draw_text_ex(font, "> 中文: 你好世界!", rl.Vector2(x = 50.0, y = 270.0), 32.0, 1.0, rl.DARKGRAY)
        rl.draw_text_ex(font, "> 日本語: こんにちは世界!", rl.Vector2(x = 50.0, y = 320.0), 32.0, 1.0, rl.DARKGRAY)

        rl.draw_rectangle_rec(
            rl.Rectangle(
                x = 400.0,
                y = 16.0,
                width = float<-font.texture.width * atlas_scale,
                height = float<-font.texture.height * atlas_scale
            ),
            rl.BLACK
        )
        rl.draw_texture_pro(
            font.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = float<-font.texture.width, height = float<-font.texture.height),
            rl.Rectangle(
                x = 400.0,
                y = 16.0,
                width = float<-font.texture.width * atlas_scale,
                height = float<-font.texture.height * atlas_scale
            ),
            rl.Vector2(x = 0.0, y = 0.0),
            0.0,
            rl.WHITE
        )
        rl.draw_rectangle_lines(400, 16, 380, 380, rl.RED)

        let atlas_size_text = rl.text_format(
            "ATLAS SIZE: %ix%i px (x%02.2f)",
            font.texture.width,
            font.texture.height,
            atlas_scale
        )
        let glyph_count_text = rl.text_format("CODEPOINTS GLYPHS LOADED: %i", font.glyphCount)
        rl.draw_text(atlas_size_text, 20, 380, 20, rl.BLUE)
        rl.draw_text(glyph_count_text, 20, 410, 20, rl.LIME)
        rl.draw_text(
            "Font: Noto Sans TC. License: SIL Open Font License 1.1",
            SCREEN_WIDTH - 300,
            SCREEN_HEIGHT - 20,
            10,
            rl.GRAY
        )

        if generated_this_frame:
            rl.draw_rectangle(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, rl.fade(rl.WHITE, 0.8))
            rl.draw_rectangle(0, 125, SCREEN_WIDTH, 200, rl.GRAY)
            rl.draw_text("GENERATING FONT ATLAS...", 120, 210, 40, rl.BLACK)

        rl.end_drawing()

    return 0
