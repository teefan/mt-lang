import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - texture outline")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let texture = rl.load_texture("fudesumi.png")
    defer rl.unload_texture(texture)
    let shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/outline.fs", GLSL_VERSION))
    defer rl.unload_shader(shader)

    var outline_size: float = 2.0
    let outline_color = array[float, 4](1.0, 0.0, 0.0, 1.0)
    let texture_size = array[float, 2](float<-texture.width, float<-texture.height)

    let outline_size_location = rl.get_shader_location(shader, "outlineSize")
    let outline_color_location = rl.get_shader_location(shader, "outlineColor")
    let texture_size_location = rl.get_shader_location(shader, "textureSize")

    rl.set_shader_value(shader, outline_size_location, outline_size, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
    rl.set_shader_value(shader, outline_color_location, outline_color, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)
    rl.set_shader_value(shader, texture_size_location, texture_size, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        outline_size += rl.get_mouse_wheel_move()
        if outline_size < 1.0:
            outline_size = 1.0
        rl.set_shader_value(shader, outline_size_location, outline_size, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.begin_shader_mode(shader)
        rl.draw_texture(texture, rl.get_screen_width() / 2 - texture.width / 2, -30, rl.WHITE)
        rl.end_shader_mode()

        rl.draw_text("Shader-based\ntexture\noutline", 10, 10, 20, rl.GRAY)
        rl.draw_text("Scroll mouse wheel to\nchange outline size", 10, 72, 20, rl.GRAY)
        rl.draw_text(rl.text_format("Outline size: %i px", int<-outline_size), 10, 120, 20, rl.MAROON)
        rl.draw_fps(710, 10)
        rl.end_drawing()

    return 0
