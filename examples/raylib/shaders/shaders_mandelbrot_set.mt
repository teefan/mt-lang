module examples.raylib.shaders.shaders_mandelbrot_set

import std.c.libm as libm
import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const zoom_speed: f32 = 1.01
const offset_speed_mul: f32 = 2.0
const starting_zoom: f32 = 0.6
const starting_offset: array[f32, 2] = array[f32, 2](-0.5, 0.0)
const shader_path_format: cstr = c"../resources/shaders/glsl%i/mandelbrot_set.fs"
const zoom_uniform_name: cstr = c"zoom"
const offset_uniform_name: cstr = c"offset"
const max_iterations_uniform_name: cstr = c"maxIterations"
const help_mouse_text: cstr = c"Press Mouse buttons right/left to zoom in/out and move"
const help_toggle_text: cstr = c"Press F1 to toggle these controls"
const help_points_text: cstr = c"Press [1 - 6] to change point of interest"
const help_iterations_text: cstr = c"Press UP | DOWN to change number of iterations"
const help_reset_text: cstr = c"Press R to recenter the camera"
const window_title: cstr = c"raylib [shaders] example - mandelbrot set"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let shader = rl.LoadShader(zero[cstr?](), rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    let target = rl.LoadRenderTexture(rl.GetScreenWidth(), rl.GetScreenHeight())
    defer rl.UnloadRenderTexture(target)

    let points_of_interest = array[array[f32, 3], 6](
        array[f32, 3](-1.76826775, -0.00422996283, 28435.9238),
        array[f32, 3](0.322004497, -0.0357099883, 56499.7266),
        array[f32, 3](-0.748880744, -0.0562955774, 9237.59082),
        array[f32, 3](-1.78385007, -0.0156200649, 14599.5283),
        array[f32, 3](-0.0985441282, -0.924688697, 26259.8535),
        array[f32, 3](0.317785531, -0.0322612226, 29297.9258),
    )

    var offset = array[f32, 2](starting_offset[0], starting_offset[1])
    var zoom: f32 = starting_zoom
    var max_iterations = 333
    var max_iterations_multiplier: f32 = 166.5

    let zoom_loc = rl.GetShaderLocation(shader, zoom_uniform_name)
    let offset_loc = rl.GetShaderLocation(shader, offset_uniform_name)
    let max_iterations_loc = rl.GetShaderLocation(shader, max_iterations_uniform_name)

    rl.SetShaderValue(shader, zoom_loc, raw(addr(zoom)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
    rl.SetShaderValue(shader, offset_loc, raw(addr(offset[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
    rl.SetShaderValue(shader, max_iterations_loc, raw(addr(max_iterations)), rl.ShaderUniformDataType.SHADER_UNIFORM_INT)

    var show_controls = true

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        var update_shader = false
        var selected_point = -1

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_ONE):
            selected_point = 0
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_TWO):
            selected_point = 1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_THREE):
            selected_point = 2
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_FOUR):
            selected_point = 3
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_FIVE):
            selected_point = 4
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_SIX):
            selected_point = 5

        if selected_point >= 0:
            offset[0] = points_of_interest[selected_point][0]
            offset[1] = points_of_interest[selected_point][1]
            zoom = points_of_interest[selected_point][2]
            update_shader = true

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_R):
            offset[0] = starting_offset[0]
            offset[1] = starting_offset[1]
            zoom = starting_zoom
            update_shader = true

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_F1):
            show_controls = not show_controls

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_UP):
            max_iterations_multiplier *= 1.4
            update_shader = true
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_DOWN):
            max_iterations_multiplier /= 1.4
            update_shader = true

        if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT) or rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT):
                zoom *= zoom_speed
            else:
                zoom *= 1.0 / zoom_speed

            let mouse_pos = rl.GetMousePosition()
            let offset_velocity = rl.Vector2(
                x = (mouse_pos.x / f32<-screen_width - 0.5) * offset_speed_mul / zoom,
                y = (mouse_pos.y / f32<-screen_height - 0.5) * offset_speed_mul / zoom,
            )

            offset[0] += rl.GetFrameTime() * offset_velocity.x
            offset[1] += rl.GetFrameTime() * offset_velocity.y
            update_shader = true

        if update_shader:
            max_iterations = i32<-(libm.sqrtf(2.0 * libm.sqrtf(libm.fabsf(1.0 - libm.sqrtf(37.5 * zoom)))) * max_iterations_multiplier)

            rl.SetShaderValue(shader, zoom_loc, raw(addr(zoom)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
            rl.SetShaderValue(shader, offset_loc, raw(addr(offset[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
            rl.SetShaderValue(shader, max_iterations_loc, raw(addr(max_iterations)), rl.ShaderUniformDataType.SHADER_UNIFORM_INT)

        rl.BeginTextureMode(target)
        rl.ClearBackground(rl.BLACK)
        rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), rl.BLACK)
        rl.EndTextureMode()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)

        rl.BeginShaderMode(shader)
        rl.DrawTextureEx(target.texture, rl.Vector2(x = 0.0, y = 0.0), 0.0, 1.0, rl.WHITE)
        rl.EndShaderMode()

        if show_controls:
            rl.DrawText(help_mouse_text, 10, 15, 10, rl.RAYWHITE)
            rl.DrawText(help_toggle_text, 10, 30, 10, rl.RAYWHITE)
            rl.DrawText(help_points_text, 10, 45, 10, rl.RAYWHITE)
            rl.DrawText(help_iterations_text, 10, 60, 10, rl.RAYWHITE)
            rl.DrawText(help_reset_text, 10, 75, 10, rl.RAYWHITE)

    return 0
