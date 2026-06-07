import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - multi sample2d")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let red_image = rl.gen_image_color(SCREEN_WIDTH, SCREEN_HEIGHT, rl.Color(r = 255, g = 0, b = 0, a = 255))
    let red_texture = rl.load_texture_from_image(red_image)
    defer rl.unload_texture(red_texture)
    rl.unload_image(red_image)

    let blue_image = rl.gen_image_color(SCREEN_WIDTH, SCREEN_HEIGHT, rl.Color(r = 0, g = 0, b = 255, a = 255))
    let blue_texture = rl.load_texture_from_image(blue_image)
    defer rl.unload_texture(blue_texture)
    rl.unload_image(blue_image)

    let shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/color_mix.fs", GLSL_VERSION))
    defer rl.unload_shader(shader)

    let blue_texture_location = rl.get_shader_location(shader, "texture1")
    let divider_location = rl.get_shader_location(shader, "divider")
    var divider_value: float = 0.5

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT):
            divider_value += 0.01
        else if rl.is_key_down(rl.KeyboardKey.KEY_LEFT):
            divider_value -= 0.01

        if divider_value < 0.0:
            divider_value = 0.0
        else if divider_value > 1.0:
            divider_value = 1.0

        rl.set_shader_value(shader, divider_location, divider_value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_shader_mode(shader)
        rl.set_shader_value_texture(shader, blue_texture_location, blue_texture)
        rl.draw_texture(red_texture, 0, 0, rl.WHITE)
        rl.end_shader_mode()

        rl.draw_text(
            "Use KEY_LEFT/KEY_RIGHT to move texture mixing in shader!",
            80,
            rl.get_screen_height() - 40,
            20,
            rl.RAYWHITE
        )
        rl.end_drawing()

    return 0
