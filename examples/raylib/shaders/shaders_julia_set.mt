module examples.raylib.shaders.shaders_julia_set

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const zoom_speed: f32 = 1.01
const offset_speed_mul: f32 = 2.0
const starting_zoom: f32 = 0.75
const shader_path_format: cstr = c"../resources/shaders/glsl%i/julia_set.fs"
const c_uniform_name: cstr = c"c"
const zoom_uniform_name: cstr = c"zoom"
const offset_uniform_name: cstr = c"offset"
const help_mouse_text: cstr = c"Press Mouse buttons right/left to zoom in/out and move"
const help_toggle_text: cstr = c"Press KEY_F1 to toggle these controls"
const help_points_text: cstr = c"Press KEYS [1 - 6] to change point of interest"
const help_speed_text: cstr = c"Press KEY_LEFT | KEY_RIGHT to change speed"
const help_pause_text: cstr = c"Press KEY_SPACE to stop movement animation"
const help_reset_text: cstr = c"Press KEY_R to recenter the camera"
const window_title: cstr = c"raylib [shaders] example - julia set"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let shader = rl.LoadShader(zero[cstr?](), rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    let target = rl.LoadRenderTexture(rl.GetScreenWidth(), rl.GetScreenHeight())
    defer rl.UnloadRenderTexture(target)

    let points_of_interest = array[array[f32, 2], 6](
        array[f32, 2](-0.348827, 0.607167),
        array[f32, 2](-0.786268, 0.169728),
        array[f32, 2](-0.8, 0.156),
        array[f32, 2](0.285, 0.0),
        array[f32, 2](-0.835, -0.2321),
        array[f32, 2](-0.70176, -0.3842),
    )

    var c_values = array[f32, 2](points_of_interest[0][0], points_of_interest[0][1])
    var offset = array[f32, 2](0.0, 0.0)
    var zoom: f32 = starting_zoom

    let c_loc = rl.GetShaderLocation(shader, c_uniform_name)
    let zoom_loc = rl.GetShaderLocation(shader, zoom_uniform_name)
    let offset_loc = rl.GetShaderLocation(shader, offset_uniform_name)

    rl.SetShaderValue(shader, c_loc, raw(addr(c_values[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
    rl.SetShaderValue(shader, zoom_loc, raw(addr(zoom)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
    rl.SetShaderValue(shader, offset_loc, raw(addr(offset[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

    var increment_speed = 0
    var show_controls = true

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
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
            c_values[0] = points_of_interest[selected_point][0]
            c_values[1] = points_of_interest[selected_point][1]
            rl.SetShaderValue(shader, c_loc, raw(addr(c_values[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_R):
            zoom = starting_zoom
            offset[0] = 0.0
            offset[1] = 0.0
            rl.SetShaderValue(shader, zoom_loc, raw(addr(zoom)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
            rl.SetShaderValue(shader, offset_loc, raw(addr(offset[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            increment_speed = 0
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_F1):
            show_controls = not show_controls

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            increment_speed += 1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
            increment_speed -= 1

        if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT) or rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_LEFT):
                zoom *= zoom_speed
            else:
                zoom *= 1.0 / zoom_speed

            let mouse_pos = rl.GetMousePosition()
            let offset_velocity = rl.Vector2(
                x = (mouse_pos.x / cast[f32](screen_width) - 0.5) * offset_speed_mul / zoom,
                y = (mouse_pos.y / cast[f32](screen_height) - 0.5) * offset_speed_mul / zoom,
            )

            offset[0] += rl.GetFrameTime() * offset_velocity.x
            offset[1] += rl.GetFrameTime() * offset_velocity.y

            rl.SetShaderValue(shader, zoom_loc, raw(addr(zoom)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
            rl.SetShaderValue(shader, offset_loc, raw(addr(offset[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

        let dc = rl.GetFrameTime() * cast[f32](increment_speed) * 0.0005
        c_values[0] += dc
        c_values[1] += dc
        rl.SetShaderValue(shader, c_loc, raw(addr(c_values[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

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
            rl.DrawText(help_speed_text, 10, 60, 10, rl.RAYWHITE)
            rl.DrawText(help_pause_text, 10, 75, 10, rl.RAYWHITE)
            rl.DrawText(help_reset_text, 10, 90, 10, rl.RAYWHITE)

    return 0
