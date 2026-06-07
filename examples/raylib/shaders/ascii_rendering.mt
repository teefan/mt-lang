import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - ascii rendering")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let fudesumi = rl.load_texture("fudesumi.png")
    defer rl.unload_texture(fudesumi)
    let raysan = rl.load_texture("raysan.png")
    defer rl.unload_texture(raysan)

    let shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/ascii.fs", GLSL_VERSION))
    defer rl.unload_shader(shader)

    let resolution_location = rl.get_shader_location(shader, "resolution")
    let font_size_location = rl.get_shader_location(shader, "fontSize")
    let resolution = rl.Vector2(x = float<-SCREEN_WIDTH, y = float<-SCREEN_HEIGHT)
    rl.set_shader_value(shader, resolution_location, resolution, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

    var font_size: float = 9.0
    var circle_position = rl.Vector2(x = 40.0, y = float<-SCREEN_HEIGHT * 0.5)
    var circle_speed: float = 1.0

    let target = rl.load_render_texture(SCREEN_WIDTH, SCREEN_HEIGHT)
    defer rl.unload_render_texture(target)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        circle_position.x += circle_speed
        if circle_position.x > 200.0 or circle_position.x < 40.0:
            circle_speed *= -1.0

        if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT) and font_size > 9.0:
            font_size -= 1.0
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT) and font_size < 15.0:
            font_size += 1.0

        rl.set_shader_value(shader, font_size_location, font_size, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

        rl.begin_texture_mode(target)
        rl.clear_background(rl.WHITE)
        rl.draw_texture(fudesumi, 500, -30, rl.WHITE)
        rl.draw_texture_v(raysan, circle_position, rl.WHITE)
        rl.end_texture_mode()

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_shader_mode(shader)
        rl.draw_texture_rec(
            target.texture,
            rl.Rectangle(
                x = 0.0,
                y = 0.0,
                width = float<-target.texture.width,
                height = -(float<-target.texture.height)
            ),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE
        )
        rl.end_shader_mode()

        rl.draw_rectangle(0, 0, SCREEN_WIDTH, 40, rl.BLACK)
        let status_text = rl.text_format("Ascii effect - FontSize:%2.0f - [Left] -1 [Right] +1 ", font_size)
        rl.draw_text(status_text, 120, 10, 20, rl.LIGHTGRAY)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
