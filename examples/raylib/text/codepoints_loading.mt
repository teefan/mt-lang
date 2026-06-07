import std.mem.heap as heap
import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function codepoint_remove_duplicates(codepoints: ptr[int], codepoint_count: int, result_count: ref[int]) -> ptr[int]:
    let codepoints_no_dups = heap.must_alloc_zeroed[int](ptr_uint<-codepoint_count)
    var index = 0
    while index < codepoint_count:
        unsafe:
            read(codepoints_no_dups + ptr_uint<-index) = read(codepoints + ptr_uint<-index)
        index += 1

    var codepoints_no_dups_count = codepoint_count
    var outer = 0
    while outer < codepoints_no_dups_count:
        var inner = outer + 1
        while inner < codepoints_no_dups_count:
            var is_duplicate = false
            unsafe:
                is_duplicate = read(codepoints_no_dups + ptr_uint<-outer) == read(codepoints_no_dups + ptr_uint<-inner)

            if is_duplicate:
                var shift = inner
                while shift < codepoints_no_dups_count - 1:
                    unsafe:
                        read(codepoints_no_dups + ptr_uint<-shift) = read(codepoints_no_dups + ptr_uint<-(shift + 1))
                    shift += 1

                codepoints_no_dups_count -= 1
            else:
                inner += 1
        outer += 1

    unsafe: read(result_count) = codepoints_no_dups_count
    return codepoints_no_dups


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [text] example - codepoints loading")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let source_text = "いろはにほへと　ちりぬるを\nわかよたれそ　つねならむ\nうゐのおくやま　けふこえて\nあさきゆめみし　ゑひもせす"

    var codepoint_count = 0
    let codepoints = rl.load_codepoints(source_text, codepoint_count) else:
        fatal("could not load codepoints")
    defer rl.unload_codepoints(codepoints)

    var codepoints_no_dups_count = 0
    let codepoints_no_dups = codepoint_remove_duplicates(codepoints, codepoint_count, ref_of(codepoints_no_dups_count))
    defer heap.release(codepoints_no_dups)

    let font = rl.load_font_ex("DotGothic16-Regular.ttf", 36, codepoints_no_dups, codepoints_no_dups_count)
    defer rl.unload_font(font)

    rl.set_texture_filter(font.texture, int<-rl.TextureFilter.TEXTURE_FILTER_BILINEAR)
    rl.set_text_line_spacing(20)

    var show_font_atlas = false

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            show_font_atlas = not show_font_atlas

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_rectangle(0, 0, rl.get_screen_width(), 70, rl.BLACK)
        let total_codepoints_text = rl.text_format("Total codepoints contained in provided text: %i", codepoint_count)
        let unique_codepoints_text = rl.text_format(
            "Total codepoints required for font atlas (duplicates excluded): %i",
            codepoints_no_dups_count
        )
        rl.draw_text(total_codepoints_text, 10, 10, 20, rl.GREEN)
        rl.draw_text(unique_codepoints_text, 10, 40, 20, rl.GREEN)

        if show_font_atlas:
            rl.draw_texture(font.texture, 150, 100, rl.BLACK)
            rl.draw_rectangle_lines(150, 100, font.texture.width, font.texture.height, rl.BLACK)
        else:
            rl.draw_text_ex(font, source_text, rl.Vector2(x = 160.0, y = 110.0), 48.0, 5.0, rl.BLACK)

        rl.draw_text("Press SPACE to toggle font atlas view!", 10, rl.get_screen_height() - 30, 20, rl.GRAY)

        rl.end_drawing()

    return 0
