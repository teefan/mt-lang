import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - eratosthenes sieve")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let target = rl.load_render_texture(SCREEN_WIDTH, SCREEN_HEIGHT)
    defer rl.unload_render_texture(target)
    let shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/eratosthenes.fs", GLSL_VERSION))
    defer rl.unload_shader(shader)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.begin_texture_mode(target)
        rl.clear_background(rl.BLACK)
        rl.draw_rectangle(0, 0, rl.get_screen_width(), rl.get_screen_height(), rl.BLACK)
        rl.end_texture_mode()

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.begin_shader_mode(shader)
        rl.draw_texture_rec(
            target.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = float<-target.texture.width, height = -(float<-target.texture.height)),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE,
        )
        rl.end_shader_mode()
        rl.end_drawing()

    return 0
