import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function clamp_size(value: float, min: float, max: float) -> float:
    if value < min:
        return min
    if value > max:
        return max
    return value


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - npatch drawing")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let n_patch_texture = rl.load_texture("ninepatch_button.png")
    defer rl.unload_texture(n_patch_texture)

    let origin = rl.Vector2(x = 0.0, y = 0.0)

    var dst_rec1 = rl.Rectangle(x = 480.0, y = 160.0, width = 32.0, height = 32.0)
    var dst_rec2 = rl.Rectangle(x = 160.0, y = 160.0, width = 32.0, height = 32.0)
    var dst_rec_h = rl.Rectangle(x = 160.0, y = 93.0, width = 32.0, height = 32.0)
    var dst_rec_v = rl.Rectangle(x = 92.0, y = 160.0, width = 32.0, height = 32.0)

    let nine_patch_info1 = rl.NPatchInfo(
        source = rl.Rectangle(x = 0.0, y = 0.0, width = 64.0, height = 64.0),
        left = 12,
        top = 40,
        right = 12,
        bottom = 12,
        layout = int<-rl.NPatchLayout.NPATCH_NINE_PATCH,
    )
    let nine_patch_info2 = rl.NPatchInfo(
        source = rl.Rectangle(x = 0.0, y = 128.0, width = 64.0, height = 64.0),
        left = 16,
        top = 16,
        right = 16,
        bottom = 16,
        layout = int<-rl.NPatchLayout.NPATCH_NINE_PATCH,
    )
    let h3_patch_info = rl.NPatchInfo(
        source = rl.Rectangle(x = 0.0, y = 64.0, width = 64.0, height = 64.0),
        left = 8,
        top = 8,
        right = 8,
        bottom = 8,
        layout = int<-rl.NPatchLayout.NPATCH_THREE_PATCH_HORIZONTAL,
    )
    let v3_patch_info = rl.NPatchInfo(
        source = rl.Rectangle(x = 0.0, y = 192.0, width = 64.0, height = 64.0),
        left = 6,
        top = 6,
        right = 6,
        bottom = 6,
        layout = int<-rl.NPatchLayout.NPATCH_THREE_PATCH_VERTICAL,
    )

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse_position = rl.get_mouse_position()

        dst_rec1.width = clamp_size(mouse_position.x - dst_rec1.x, 1.0, 300.0)
        dst_rec1.height = clamp_size(mouse_position.y - dst_rec1.y, 1.0, mouse_position.y - dst_rec1.y)
        dst_rec2.width = clamp_size(mouse_position.x - dst_rec2.x, 1.0, 300.0)
        dst_rec2.height = clamp_size(mouse_position.y - dst_rec2.y, 1.0, mouse_position.y - dst_rec2.y)
        dst_rec_h.width = clamp_size(mouse_position.x - dst_rec_h.x, 1.0, mouse_position.x - dst_rec_h.x)
        dst_rec_v.height = clamp_size(mouse_position.y - dst_rec_v.y, 1.0, mouse_position.y - dst_rec_v.y)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.draw_texture_n_patch(n_patch_texture, nine_patch_info2, dst_rec2, origin, 0.0, rl.WHITE)
        rl.draw_texture_n_patch(n_patch_texture, nine_patch_info1, dst_rec1, origin, 0.0, rl.WHITE)
        rl.draw_texture_n_patch(n_patch_texture, h3_patch_info, dst_rec_h, origin, 0.0, rl.WHITE)
        rl.draw_texture_n_patch(n_patch_texture, v3_patch_info, dst_rec_v, origin, 0.0, rl.WHITE)

        rl.draw_rectangle_lines(5, 88, 74, 266, rl.BLUE)
        rl.draw_texture(n_patch_texture, 10, 93, rl.WHITE)
        rl.draw_text("TEXTURE", 15, 360, 10, rl.DARKGRAY)
        rl.draw_text("Move the mouse to stretch or shrink the n-patches", 10, 20, 20, rl.DARKGRAY)

        rl.end_drawing()

    return 0
