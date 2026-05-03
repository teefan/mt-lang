module examples.raylib.text.text_codepoints_loading

import std.c.raylib as rl
import std.mem.heap as heap

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [text] example - codepoints loading"
const text: cstr = c"いろはにほへと　ちりぬるを\nわかよたれそconst font_path: cstr = c"../resources/DotGothic16-Regular.ttf"
const total_codepoints_format: cstr = c"Total codepoints contained in provided text: %i"
const atlas_codepoints_format: cstr = c"Total codepoints required for font atlas (duplicates excluded): %i"
const toggle_atlas_text: cstr = c"Press SPACE to toggle font atlas view!"


def codepoint_remove_duplicates(codepoints: ptr[i32], codepoint_count: i32, codepoints_result_count: ptr[i32]) -> ptr[i32]:
    let codepoints_no_dups = heap.must_alloc_zeroed[i32](usize<-codepoint_count)
    var codepoints_no_dups_count = codepoint_count

    unsafe:
        for index in range(0, codepoint_count):
            read(codepoints_no_dups + index) = read(codepoints + index)

        for index in range(0, codepoints_no_dups_count):
            var check = index + 1
            while check < codepoints_no_dups_count:
                if read(codepoints_no_dups + index) == read(codepoints_no_dups + check):
                    var shift = check
                    while shift + 1 < codepoints_no_dups_count:
                        read(codepoints_no_dups + shift) = read(codepoints_no_dups + shift + 1)
                        shift += 1
                    codepoints_no_dups_count -= 1
                else:
                    check += 1

        read(codepoints_result_count) = codepoints_no_dups_count

    return codepoints_no_dups


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var codepoint_count = 0
    let codepoints = rl.LoadCodepoints(text, ptr_of(ref_of(codepoint_count)))
    defer rl.UnloadCodepoints(codepoints)

    var codepoints_no_dups_count = 0
    let codepoints_no_dups = codepoint_remove_duplicates(codepoints, codepoint_count, ptr_of(ref_of(codepoints_no_dups_count)))
    defer heap.release(codepoints_no_dups)

    let font = rl.LoadFontEx(font_path, 36, codepoints_no_dups, codepoints_no_dups_count)
    defer rl.UnloadFont(font)

    rl.SetTextureFilter(font.texture, rl.TextureFilter.TEXTURE_FILTER_BILINEAR)
    rl.SetTextLineSpacing(20)

    var show_font_atlas = false

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            show_font_atlas = not show_font_atlas

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.DrawRectangle(0, 0, rl.GetScreenWidth(), 70, rl.BLACK)
        rl.DrawText(rl.TextFormat(total_codepoints_format, codepoint_count), 10, 10, 20, rl.GREEN)
        rl.DrawText(rl.TextFormat(atlas_codepoints_format, codepoints_no_dups_count), 10, 40, 20, rl.GREEN)

        if show_font_atlas:
            rl.DrawTexture(font.texture, 150, 100, rl.BLACK)
            rl.DrawRectangleLines(150, 100, font.texture.width, font.texture.height, rl.BLACK)
        else:
            rl.DrawTextEx(font, text, rl.Vector2(x = 160.0, y = 110.0), 48.0, 5.0, rl.BLACK)

        rl.DrawText(toggle_atlas_text, 10, rl.GetScreenHeight() - 30, 20, rl.GRAY)

    return 0
