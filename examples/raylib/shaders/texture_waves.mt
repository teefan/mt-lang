import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - texture waves")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let texture = rl.load_texture("space.png")
    defer rl.unload_texture(texture)

    let shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/wave.fs", GLSL_VERSION))
    defer rl.unload_shader(shader)

    let seconds_location = rl.get_shader_location(shader, "seconds")
    let freq_x_location = rl.get_shader_location(shader, "freqX")
    let freq_y_location = rl.get_shader_location(shader, "freqY")
    let amp_x_location = rl.get_shader_location(shader, "ampX")
    let amp_y_location = rl.get_shader_location(shader, "ampY")
    let speed_x_location = rl.get_shader_location(shader, "speedX")
    let speed_y_location = rl.get_shader_location(shader, "speedY")
    let size_location = rl.get_shader_location(shader, "size")

    let screen_size = rl.Vector2(x = float<-rl.get_screen_width(), y = float<-rl.get_screen_height())
    let freq_x: float = 25.0
    let freq_y: float = 25.0
    let amp_x: float = 5.0
    let amp_y: float = 5.0
    let speed_x: float = 8.0
    let speed_y: float = 8.0

    rl.set_shader_value(shader, size_location, screen_size, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
    rl.set_shader_value(shader, freq_x_location, freq_x, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
    rl.set_shader_value(shader, freq_y_location, freq_y, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
    rl.set_shader_value(shader, amp_x_location, amp_x, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
    rl.set_shader_value(shader, amp_y_location, amp_y, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
    rl.set_shader_value(shader, speed_x_location, speed_x, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
    rl.set_shader_value(shader, speed_y_location, speed_y, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

    var seconds: float = 0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        seconds += rl.get_frame_time()
        rl.set_shader_value(shader, seconds_location, seconds, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_shader_mode(shader)
        rl.draw_texture(texture, 0, 0, rl.WHITE)
        rl.draw_texture(texture, texture.width, 0, rl.WHITE)
        rl.end_shader_mode()

        rl.end_drawing()

    return 0
