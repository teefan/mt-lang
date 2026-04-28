module examples.idiomatic.raylib.blend_modes

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const background_path: str = "../../raylib/textures/resources/cyberpunk_street_background.png"
const foreground_path: str = "../../raylib/textures/resources/cyberpunk_street_foreground.png"
const blend_count_max: i32 = 4

def blend_label(blend_mode: i32) -> str:
    if blend_mode == rl.BlendMode.BLEND_ALPHA:
        return "Current: BLEND_ALPHA"
    elif blend_mode == rl.BlendMode.BLEND_ADDITIVE:
        return "Current: BLEND_ADDITIVE"
    elif blend_mode == rl.BlendMode.BLEND_MULTIPLIED:
        return "Current: BLEND_MULTIPLIED"
    return "Current: BLEND_ADD_COLORS"

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Blend Modes")
    defer rl.close_window()

    let background_texture = rl.load_texture(background_path)
    let foreground_texture = rl.load_texture(foreground_path)
    defer:
        rl.unload_texture(foreground_texture)
        rl.unload_texture(background_texture)

    var blend_mode: i32 = rl.BlendMode.BLEND_ALPHA

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            if blend_mode >= blend_count_max - 1:
                blend_mode = 0
            else:
                blend_mode += 1

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_texture(background_texture, screen_width / 2 - background_texture.width / 2, screen_height / 2 - background_texture.height / 2, rl.WHITE)

        rl.begin_blend_mode(blend_mode)
        rl.draw_texture(foreground_texture, screen_width / 2 - foreground_texture.width / 2, screen_height / 2 - foreground_texture.height / 2, rl.WHITE)
        rl.end_blend_mode()

        rl.draw_text("Press SPACE to change blend modes.", 310, 350, 10, rl.GRAY)
        rl.draw_text(blend_label(blend_mode), screen_width / 2 - 60, 370, 10, rl.GRAY)
        rl.draw_text("(c) Cyberpunk Street Environment by Luis Zuno (@ansimuz)", screen_width - 330, screen_height - 20, 10, rl.GRAY)

    return 0
