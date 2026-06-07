import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - texture rendering")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let blank = rl.gen_image_color(1024, 1024, rl.BLANK)
    let texture = rl.load_texture_from_image(blank)
    defer rl.unload_texture(texture)
    rl.unload_image(blank)

    let shader_path = rl.text_format("shaders/glsl%i/cubes_panning.fs", GLSL_VERSION)
    let shader = rl.load_shader(null, shader_path)
    defer rl.unload_shader(shader)

    let time_location = rl.get_shader_location(shader, "uTime")
    var time: float = 0.0
    rl.set_shader_value(shader, time_location, time, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        time = float<-rl.get_time()
        rl.set_shader_value(shader, time_location, time, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_shader_mode(shader)
        rl.draw_texture(texture, 0, 0, rl.WHITE)
        rl.end_shader_mode()

        rl.draw_text("BACKGROUND is PAINTED and ANIMATED on SHADER!", 10, 10, 20, rl.MAROON)
        rl.end_drawing()

    return 0
