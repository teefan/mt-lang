module examples.idiomatic.raylib.npatch_drawing

import std.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const npatch_texture_path: str = "../../raylib/resources/ninepatch_button.png"


def clamp_min(value: f32, minimum: f32) -> f32:
    if value < minimum:
        return minimum
    return value


def clamp_width(value: f32) -> f32:
    if value < 1.0:
        return 1.0
    if value > 300.0:
        return 300.0
    return value


def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea N-Patch Drawing")
    defer rl.close_window()

    let npatch_texture = rl.load_texture(npatch_texture_path)
    defer rl.unload_texture(npatch_texture)

    let origin = rl.Vector2(x = 0.0, y = 0.0)

    var dst_rec_1 = rl.Rectangle(x = 480.0, y = 160.0, width = 32.0, height = 32.0)
    var dst_rec_2 = rl.Rectangle(x = 160.0, y = 160.0, width = 32.0, height = 32.0)
    var dst_rec_h = rl.Rectangle(x = 160.0, y = 93.0, width = 32.0, height = 32.0)
    var dst_rec_v = rl.Rectangle(x = 92.0, y = 160.0, width = 32.0, height = 32.0)

    let nine_patch_info_1 = rl.NPatchInfo(
        source = rl.Rectangle(x = 0.0, y = 0.0, width = 64.0, height = 64.0),
        left = 12,
        top = 40,
        right = 12,
        bottom = 12,
        layout = rl.NPatchLayout.NPATCH_NINE_PATCH,
    )
    let nine_patch_info_2 = rl.NPatchInfo(
        source = rl.Rectangle(x = 0.0, y = 128.0, width = 64.0, height = 64.0),
        left = 16,
        top = 16,
        right = 16,
        bottom = 16,
        layout = rl.NPatchLayout.NPATCH_NINE_PATCH,
    )
    let h3_patch_info = rl.NPatchInfo(
        source = rl.Rectangle(x = 0.0, y = 64.0, width = 64.0, height = 64.0),
        left = 8,
        top = 8,
        right = 8,
        bottom = 8,
        layout = rl.NPatchLayout.NPATCH_THREE_PATCH_HORIZONTAL,
    )
    let v3_patch_info = rl.NPatchInfo(
        source = rl.Rectangle(x = 0.0, y = 192.0, width = 64.0, height = 64.0),
        left = 6,
        top = 6,
        right = 6,
        bottom = 6,
        layout = rl.NPatchLayout.NPATCH_THREE_PATCH_VERTICAL,
    )

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse_position = rl.get_mouse_position()

        dst_rec_1.width = clamp_width(mouse_position.x - dst_rec_1.x)
        dst_rec_1.height = clamp_min(mouse_position.y - dst_rec_1.y, 1.0)
        dst_rec_2.width = clamp_width(mouse_position.x - dst_rec_2.x)
        dst_rec_2.height = clamp_min(mouse_position.y - dst_rec_2.y, 1.0)
        dst_rec_h.width = clamp_min(mouse_position.x - dst_rec_h.x, 1.0)
        dst_rec_v.height = clamp_min(mouse_position.y - dst_rec_v.y, 1.0)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)

        rl.draw_texture_n_patch(npatch_texture, nine_patch_info_2, dst_rec_2, origin, 0.0, rl.WHITE)
        rl.draw_texture_n_patch(npatch_texture, nine_patch_info_1, dst_rec_1, origin, 0.0, rl.WHITE)
        rl.draw_texture_n_patch(npatch_texture, h3_patch_info, dst_rec_h, origin, 0.0, rl.WHITE)
        rl.draw_texture_n_patch(npatch_texture, v3_patch_info, dst_rec_v, origin, 0.0, rl.WHITE)

        rl.draw_rectangle_lines(5, 88, 74, 266, rl.BLUE)
        rl.draw_texture(npatch_texture, 10, 93, rl.WHITE)
        rl.draw_text("TEXTURE", 15, 360, 10, rl.DARKGRAY)
        rl.draw_text("Move the mouse to stretch or shrink the n-patches", 10, 20, 20, rl.DARKGRAY)

    return 0
