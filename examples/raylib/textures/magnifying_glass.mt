import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.rlgl as rlgl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLASS_SIZE: int = 256
const GLASS_RADIUS: float = 128.0


function draw_world(parrots: rl.Texture2D) -> void:
    rl.draw_texture(parrots, 144, 33, rl.WHITE)
    rl.draw_text("Use the magnifying glass to find hidden bunnies!", 154, 6, 20, rl.BLACK)


function draw_hidden_bunnies(bunny: rl.Texture2D) -> void:
    rl.begin_blend_mode(int<-rl.BlendMode.BLEND_MULTIPLIED)
    rl.draw_texture(bunny, 250, 350, rl.WHITE)
    rl.draw_texture(bunny, 500, 100, rl.WHITE)
    rl.draw_texture(bunny, 420, 300, rl.WHITE)
    rl.draw_texture(bunny, 650, 10, rl.WHITE)
    rl.end_blend_mode()


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [textures] example - magnifying glass")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let bunny = rl.load_texture("raybunny.png")
    defer rl.unload_texture(bunny)
    let parrots = rl.load_texture("parrots.png")
    defer rl.unload_texture(parrots)

    var circle = rl.gen_image_color(GLASS_SIZE, GLASS_SIZE, rl.BLANK)
    rl.image_draw_circle(circle, GLASS_SIZE / 2, GLASS_SIZE / 2, GLASS_SIZE / 2, rl.WHITE)
    let mask = rl.load_texture_from_image(circle)
    defer rl.unload_texture(mask)
    rl.unload_image(circle)

    let magnified_world = rl.load_render_texture(GLASS_SIZE, GLASS_SIZE)
    defer rl.unload_render_texture(magnified_world)

    var camera = rl.Camera2D(
        offset = rl.Vector2(x = GLASS_RADIUS, y = GLASS_RADIUS),
        target = rl.Vector2(x = 0.0, y = 0.0),
        rotation = 0.0,
        zoom = 2.0,
    )

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let mouse_pos = rl.get_mouse_position()
        camera.target = mouse_pos

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        draw_world(parrots)

        rl.begin_texture_mode(magnified_world)
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_2d(camera)
        draw_world(parrots)
        draw_hidden_bunnies(bunny)
        rl.end_mode_2d()

        rl.begin_blend_mode(int<-rl.BlendMode.BLEND_CUSTOM_SEPARATE)
        rlgl.set_blend_factors_separate(
            rlgl.RL_ZERO,
            rlgl.RL_ONE,
            rlgl.RL_ONE,
            rlgl.RL_ZERO,
            rlgl.RL_FUNC_ADD,
            rlgl.RL_FUNC_ADD,
        )
        rl.draw_texture(mask, 0, 0, rl.WHITE)
        rl.end_blend_mode()

        rl.end_texture_mode()

        rl.draw_texture_rec(
            magnified_world.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = float<-GLASS_SIZE, height = -float<-GLASS_SIZE),
            rl.Vector2(x = mouse_pos.x - GLASS_RADIUS, y = mouse_pos.y - GLASS_RADIUS),
            rl.WHITE,
        )
        rl.draw_ring(mouse_pos, GLASS_RADIUS - 2.0, GLASS_RADIUS + 2.0, 0.0, 360.0, 64, rl.BLACK)

        let highlight_pos = rl.Vector2(
            x = mouse_pos.x - (64.0 * (mouse_pos.x / float<-SCREEN_WIDTH)) - 32.0,
            y = mouse_pos.y - (64.0 * (mouse_pos.y / float<-SCREEN_WIDTH)) - 32.0,
        )
        rl.draw_circle_v(highlight_pos, 4.0, rl.color_alpha(rl.WHITE, 0.5))

        rl.end_drawing()

    return 0
