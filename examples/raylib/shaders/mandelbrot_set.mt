import std.math as math
import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330
const ZOOM_SPEED: float = 1.01
const OFFSET_SPEED_MULTIPLIER: float = 2.0
const STARTING_ZOOM: float = 0.6
const STARTING_OFFSET: array[float, 2] = array[float, 2](-0.5, 0.0)

const POINTS_OF_INTEREST: array[array[float, 3], 6] = array[array[float, 3], 6](
    array[float, 3](-1.76826775, -0.00422996283, 28435.9238),
    array[float, 3](0.322004497, -0.0357099883, 56499.7266),
    array[float, 3](-0.748880744, -0.0562955774, 9237.59082),
    array[float, 3](-1.78385007, -0.0156200649, 14599.5283),
    array[float, 3](-0.0985441282, -0.924688697, 26259.8535),
    array[float, 3](0.317785531, -0.0322612226, 29297.9258),
)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - mandelbrot set")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/mandelbrot_set.fs", GLSL_VERSION))
    defer rl.unload_shader(shader)

    let target = rl.load_render_texture(rl.get_screen_width(), rl.get_screen_height())
    defer rl.unload_render_texture(target)

    var offset = STARTING_OFFSET
    var zoom = STARTING_ZOOM
    var max_iterations = 333
    var max_iterations_multiplier: float = 166.5

    let zoom_location = rl.get_shader_location(shader, "zoom")
    let offset_location = rl.get_shader_location(shader, "offset")
    let max_iterations_location = rl.get_shader_location(shader, "maxIterations")

    rl.set_shader_value(shader, zoom_location, zoom, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
    rl.set_shader_value(shader, offset_location, offset, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
    rl.set_shader_value(shader, max_iterations_location, max_iterations, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT)

    var show_controls = true
    rl.set_target_fps(60)

    while not rl.window_should_close():
        var update_shader = false

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            offset[0] = POINTS_OF_INTEREST[0][0]
            offset[1] = POINTS_OF_INTEREST[0][1]
            zoom = POINTS_OF_INTEREST[0][2]
            update_shader = true
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            offset[0] = POINTS_OF_INTEREST[1][0]
            offset[1] = POINTS_OF_INTEREST[1][1]
            zoom = POINTS_OF_INTEREST[1][2]
            update_shader = true
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            offset[0] = POINTS_OF_INTEREST[2][0]
            offset[1] = POINTS_OF_INTEREST[2][1]
            zoom = POINTS_OF_INTEREST[2][2]
            update_shader = true
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_FOUR):
            offset[0] = POINTS_OF_INTEREST[3][0]
            offset[1] = POINTS_OF_INTEREST[3][1]
            zoom = POINTS_OF_INTEREST[3][2]
            update_shader = true
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_FIVE):
            offset[0] = POINTS_OF_INTEREST[4][0]
            offset[1] = POINTS_OF_INTEREST[4][1]
            zoom = POINTS_OF_INTEREST[4][2]
            update_shader = true
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_SIX):
            offset[0] = POINTS_OF_INTEREST[5][0]
            offset[1] = POINTS_OF_INTEREST[5][1]
            zoom = POINTS_OF_INTEREST[5][2]
            update_shader = true

        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            offset = STARTING_OFFSET
            zoom = STARTING_ZOOM
            update_shader = true

        if rl.is_key_pressed(rl.KeyboardKey.KEY_F1):
            show_controls = not show_controls

        if rl.is_key_pressed(rl.KeyboardKey.KEY_UP):
            max_iterations_multiplier *= 1.4
            update_shader = true
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_DOWN):
            max_iterations_multiplier /= 1.4
            update_shader = true

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
            update_shader = true

        if update_shader:
            let zoom_term = math.sqrt(37.5 * double<-zoom)
            let iteration_curve = math.sqrt(2.0 * math.sqrt(math.abs(1.0 - zoom_term)))
            max_iterations = int<-(iteration_curve * double<-max_iterations_multiplier)
            rl.set_shader_value(shader, zoom_location, zoom, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
            rl.set_shader_value(shader, offset_location, offset, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
            rl.set_shader_value(shader, max_iterations_location, max_iterations, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT)

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
            rl.draw_text("Press F1 to toggle these controls", 10, 30, 10, rl.RAYWHITE)
            rl.draw_text("Press [1 - 6] to change point of interest", 10, 45, 10, rl.RAYWHITE)
            rl.draw_text("Press UP | DOWN to change number of iterations", 10, 60, 10, rl.RAYWHITE)
            rl.draw_text("Press R to recenter the camera", 10, 75, 10, rl.RAYWHITE)
        rl.end_drawing()

    return 0
