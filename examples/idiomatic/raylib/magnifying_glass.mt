module examples.idiomatic.raylib.magnifying_glass

import std.raylib as rl
import std.rlgl as rlgl

const screen_width: i32 = 800
const screen_height: i32 = 450
const glass_size: i32 = 256
const glass_radius: f32 = 128.0
const bunny_path: str = "../../raylib/resources/raybunny.png"
const parrots_path: str = "../../raylib/resources/parrots.png"

def main() -> i32:
    rl.init_window(screen_width, screen_height, "Milk Tea Magnifying Glass")
    defer rl.close_window()

    let bunny = rl.load_texture(bunny_path)
    let parrots = rl.load_texture(parrots_path)

    var circle = rl.gen_image_color(glass_size, glass_size, rl.BLANK)
    rl.image_draw_circle(inout circle, 128, 128, 128, rl.WHITE)
    let mask = rl.load_texture_from_image(circle)
    rl.unload_image(circle)

    let magnified_world = rl.load_render_texture(glass_size, glass_size)

    defer:
        rl.unload_render_texture(magnified_world)
        rl.unload_texture(mask)
        rl.unload_texture(parrots)
        rl.unload_texture(bunny)

    var camera = zero[rl.Camera2D]()
    camera.zoom = 2.0
    camera.offset = rl.Vector2(x = glass_radius, y = glass_radius)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse_pos = rl.get_mouse_position()
        camera.target = mouse_pos

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.draw_texture(parrots, 144, 33, rl.WHITE)
        rl.draw_text("Use the magnifying glass to find hidden bunnies!", 154, 6, 20, rl.BLACK)

        rl.begin_texture_mode(magnified_world)
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_2d(camera)
        rl.draw_texture(parrots, 144, 33, rl.WHITE)
        rl.draw_text("Use the magnifying glass to find hidden bunnies!", 154, 6, 20, rl.BLACK)

        rl.begin_blend_mode(rl.BlendMode.BLEND_MULTIPLIED)
        rl.draw_texture(bunny, 250, 350, rl.WHITE)
        rl.draw_texture(bunny, 500, 100, rl.WHITE)
        rl.draw_texture(bunny, 420, 300, rl.WHITE)
        rl.draw_texture(bunny, 650, 10, rl.WHITE)
        rl.end_blend_mode()
        rl.end_mode_2d()

        rl.begin_blend_mode(rl.BlendMode.BLEND_CUSTOM_SEPARATE)
        rlgl.set_blend_factors_separate(rlgl.RL_ZERO, rlgl.RL_ONE, rlgl.RL_ONE, rlgl.RL_ZERO, rlgl.RL_FUNC_ADD, rlgl.RL_FUNC_ADD)
        rl.draw_texture(mask, 0, 0, rl.WHITE)
        rl.end_blend_mode()
        rl.end_texture_mode()

        rl.draw_texture_rec(
            magnified_world.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = f32<-glass_size, height = -f32<-glass_size),
            rl.Vector2(x = mouse_pos.x - glass_radius, y = mouse_pos.y - glass_radius),
            rl.WHITE,
        )

        rl.draw_ring(mouse_pos, 126.0, 130.0, 0.0, 360.0, 64, rl.BLACK)

        let rx = mouse_pos.x / f32<-screen_width
        let ry = mouse_pos.y / f32<-screen_width
        rl.draw_circle(i32<-(mouse_pos.x - 64.0 * rx) - 32, i32<-(mouse_pos.y - 64.0 * ry) - 32, 4.0, rl.color_alpha(rl.WHITE, 0.5))

    return 0
