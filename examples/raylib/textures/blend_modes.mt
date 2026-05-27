import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const BLEND_COUNT_MAX: int = 4

function current_blend_mode_label(blend_mode: int) -> cstr:
    if blend_mode == int<-rl.BlendMode.BLEND_ALPHA:
        return "Current: BLEND_ALPHA"
    if blend_mode == int<-rl.BlendMode.BLEND_ADDITIVE:
        return "Current: BLEND_ADDITIVE"
    if blend_mode == int<-rl.BlendMode.BLEND_MULTIPLIED:
        return "Current: BLEND_MULTIPLIED"
    if blend_mode == int<-rl.BlendMode.BLEND_ADD_COLORS:
        return "Current: BLEND_ADD_COLORS"
    return ""

function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - blend modes")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let bg_image = rl.load_image("cyberpunk_street_background.png")
    defer rl.unload_image(bg_image)
    let bg_texture = rl.load_texture_from_image(bg_image)
    defer rl.unload_texture(bg_texture)

    let fg_image = rl.load_image("cyberpunk_street_foreground.png")
    defer rl.unload_image(fg_image)
    let fg_texture = rl.load_texture_from_image(fg_image)
    defer rl.unload_texture(fg_texture)

    var blend_mode = int<-rl.BlendMode.BLEND_ALPHA

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            if blend_mode >= BLEND_COUNT_MAX - 1:
                blend_mode = 0
            else:
                blend_mode += 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_texture(bg_texture, SCREEN_WIDTH / 2 - bg_texture.width / 2, SCREEN_HEIGHT / 2 - bg_texture.height / 2, rl.WHITE)

        rl.begin_blend_mode(blend_mode)
        rl.draw_texture(fg_texture, SCREEN_WIDTH / 2 - fg_texture.width / 2, SCREEN_HEIGHT / 2 - fg_texture.height / 2, rl.WHITE)
        rl.end_blend_mode()

        rl.draw_text("Press SPACE to change blend modes.", 310, 350, 10, rl.GRAY)
        rl.draw_text(current_blend_mode_label(blend_mode), SCREEN_WIDTH / 2 - 60, 370, 10, rl.GRAY)
        rl.draw_text("(c) Cyberpunk Street Environment by Luis Zuno (@ansimuz)", SCREEN_WIDTH - 330, SCREEN_HEIGHT - 20, 10, rl.GRAY)
        rl.end_drawing()

    return 0
