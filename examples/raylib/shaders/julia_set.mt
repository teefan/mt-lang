import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330
const ZOOM_SPEED: float = 1.01
const OFFSET_SPEED_MULTIPLIER: float = 2.0
const STARTING_ZOOM: float = 0.75

const POINTS_OF_INTEREST: array[array[float, 2], 6] = array[array[float, 2], 6](
    array[float, 2](-0.348827, 0.607167),
    array[float, 2](-0.786268, 0.169728),
    array[float, 2](-0.8, 0.156),
    array[float, 2](0.285, 0.0),
    array[float, 2](-0.835, -0.2321),
    array[float, 2](-0.70176, -0.3842),
)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - julia set")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/julia_set.fs", GLSL_VERSION))
    defer rl.unload_shader(shader)

    let target = rl.load_render_texture(rl.get_screen_width(), rl.get_screen_height())
    defer rl.unload_render_texture(target)

    var c = POINTS_OF_INTEREST[0]
    var offset = array[float, 2](0.0, 0.0)
    var zoom = STARTING_ZOOM

    let c_location = rl.get_shader_location(shader, "c")
    let zoom_location = rl.get_shader_location(shader, "zoom")
    let offset_location = rl.get_shader_location(shader, "offset")

    rl.set_shader_value(shader, c_location, c, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
    rl.set_shader_value(shader, zoom_location, zoom, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
    rl.set_shader_value(shader, offset_location, offset, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

    var increment_speed = 0
    var show_controls = true

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            c = POINTS_OF_INTEREST[0]
            rl.set_shader_value(shader, c_location, c, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            c = POINTS_OF_INTEREST[1]
            rl.set_shader_value(shader, c_location, c, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            c = POINTS_OF_INTEREST[2]
            rl.set_shader_value(shader, c_location, c, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_FOUR):
            c = POINTS_OF_INTEREST[3]
            rl.set_shader_value(shader, c_location, c, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_FIVE):
            c = POINTS_OF_INTEREST[4]
            rl.set_shader_value(shader, c_location, c, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_SIX):
            c = POINTS_OF_INTEREST[5]
            rl.set_shader_value(shader, c_location, c, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            zoom = STARTING_ZOOM
            offset = array[float, 2](0.0, 0.0)
            rl.set_shader_value(shader, zoom_location, zoom, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
            rl.set_shader_value(shader, offset_location, offset, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            increment_speed = 0
        if rl.is_key_pressed(rl.KeyboardKey.KEY_F1):
            show_controls = not show_controls
        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            increment_speed += 1
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            increment_speed -= 1

        if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT) or rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_LEFT):
                zoom *= ZOOM_SPEED
            else:
                zoom *= 1.0 / ZOOM_SPEED

            let mouse_position = rl.get_mouse_position()
            let offset_velocity = rl.Vector2(
                x = (mouse_position.x / float<-SCREEN_WIDTH - 0.5) * OFFSET_SPEED_MULTIPLIER / zoom,
                y = (mouse_position.y / float<-SCREEN_HEIGHT - 0.5) * OFFSET_SPEED_MULTIPLIER / zoom,
            )
            offset[0] += rl.get_frame_time() * offset_velocity.x
            offset[1] += rl.get_frame_time() * offset_velocity.y
            rl.set_shader_value(shader, zoom_location, zoom, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
            rl.set_shader_value(shader, offset_location, offset, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

        let dc = rl.get_frame_time() * float<-increment_speed * 0.0005
        c[0] += dc
        c[1] += dc
        rl.set_shader_value(shader, c_location, c, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

        rl.begin_texture_mode(target)
        rl.clear_background(rl.BLACK)
        rl.draw_rectangle(0, 0, rl.get_screen_width(), rl.get_screen_height(), rl.BLACK)
        rl.end_texture_mode()

        rl.begin_drawing()
        rl.clear_background(rl.BLACK)
        rl.begin_shader_mode(shader)
        rl.draw_texture_ex(target.texture, rl.Vector2(x = 0.0, y = 0.0), 0.0, 1.0, rl.WHITE)
        rl.end_shader_mode()

        if show_controls:
            rl.draw_text("Press Mouse buttons right/left to zoom in/out and move", 10, 15, 10, rl.RAYWHITE)
            rl.draw_text("Press KEY_F1 to toggle these controls", 10, 30, 10, rl.RAYWHITE)
            rl.draw_text("Press KEYS [1 - 6] to change point of interest", 10, 45, 10, rl.RAYWHITE)
            rl.draw_text("Press KEY_LEFT | KEY_RIGHT to change speed", 10, 60, 10, rl.RAYWHITE)
            rl.draw_text("Press KEY_SPACE to stop movement animation", 10, 75, 10, rl.RAYWHITE)
            rl.draw_text("Press KEY_R to recenter the camera", 10, 90, 10, rl.RAYWHITE)
        rl.end_drawing()

    return 0
