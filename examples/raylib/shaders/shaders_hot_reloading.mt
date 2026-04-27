module examples.raylib.shaders.shaders_hot_reloading

import std.c.raylib as rl
import std.c.rlgl as rlgl
import std.c.time as ctime

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const shader_file_name_format: cstr = c"resources/shaders/glsl%i/reload.fs"
const resolution_uniform_name: cstr = c"resolution"
const mouse_uniform_name: cstr = c"mouse"
const time_uniform_name: cstr = c"time"
const reload_status_format: cstr = c"PRESS [A] to TOGGLE SHADER AUTOLOADING: %s"
const reload_manual_text: cstr = c"MOUSE CLICK to SHADER RE-LOADING"
const modification_time_format: cstr = c"%Y-%m-%d %H:%M:%S"
const modification_time_text_format: cstr = c"Shader last modification: %s"
const auto_text: cstr = c"AUTO"
const manual_text: cstr = c"MANUAL"
const window_title: cstr = c"raylib [shaders] example - hot reloading"

def null_cstr() -> cstr:
    unsafe:
        return cast[cstr](null[ptr[char]])

def f32_ptr_to_void(value: ptr[f32]) -> ptr[void]:
    unsafe:
        return cast[ptr[void]](value)

def formatted_mod_time(mod_time: ref[ctime.time_t], buffer: ref[array[char, 64]]) -> cstr:
    let tm_info = ctime.localtime(raw(addr(value(mod_time))))

    unsafe:
        ctime.strftime(raw(addr(value(buffer)[0])), 64, modification_time_format, tm_info)
        return cast[cstr](raw(addr(value(buffer)[0])))

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let shader_path = rl.TextFormat(shader_file_name_format, glsl_version)
    var frag_shader_mod_time: ctime.time_t = rl.GetFileModTime(shader_path)
    var shader = rl.LoadShader(null_cstr(), shader_path)

    var resolution_location = rl.GetShaderLocation(shader, resolution_uniform_name)
    var mouse_location = rl.GetShaderLocation(shader, mouse_uniform_name)
    var time_location = rl.GetShaderLocation(shader, time_uniform_name)

    var resolution = array[f32, 2](cast[f32](screen_width), cast[f32](screen_height))
    rl.SetShaderValue(shader, resolution_location, f32_ptr_to_void(raw(addr(resolution[0]))), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

    var total_time: f32 = 0.0
    var shader_auto_reloading = false
    var mod_time_buffer = zero[array[char, 64]]()

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        total_time += cast[f32](rl.GetFrameTime())

        let mouse = rl.GetMousePosition()
        var mouse_position = array[f32, 2](mouse.x, mouse.y)

        rl.SetShaderValue(shader, time_location, f32_ptr_to_void(raw(addr(total_time))), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.SetShaderValue(shader, mouse_location, f32_ptr_to_void(raw(addr(mouse_position[0]))), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

        if shader_auto_reloading or rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            let current_frag_shader_mod_time = rl.GetFileModTime(shader_path)

            if current_frag_shader_mod_time != frag_shader_mod_time:
                let updated_shader = rl.LoadShader(null_cstr(), shader_path)

                if updated_shader.id != rlgl.rlGetShaderIdDefault():
                    rl.UnloadShader(shader)
                    shader = updated_shader

                    resolution_location = rl.GetShaderLocation(shader, resolution_uniform_name)
                    mouse_location = rl.GetShaderLocation(shader, mouse_uniform_name)
                    time_location = rl.GetShaderLocation(shader, time_uniform_name)

                    rl.SetShaderValue(shader, resolution_location, f32_ptr_to_void(raw(addr(resolution[0]))), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

                frag_shader_mod_time = current_frag_shader_mod_time

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_A):
            shader_auto_reloading = not shader_auto_reloading

        let reload_mode_text = if shader_auto_reloading then auto_text else manual_text
        let reload_mode_color = if shader_auto_reloading then rl.RED else rl.BLACK
        let modification_time_text = formatted_mod_time(addr(frag_shader_mod_time), addr(mod_time_buffer))

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginShaderMode(shader)
        rl.DrawRectangle(0, 0, screen_width, screen_height, rl.WHITE)
        rl.EndShaderMode()

        rl.DrawText(rl.TextFormat(reload_status_format, reload_mode_text), 10, 10, 10, reload_mode_color)
        if not shader_auto_reloading:
            rl.DrawText(reload_manual_text, 10, 30, 10, rl.BLACK)

        rl.DrawText(rl.TextFormat(modification_time_text_format, modification_time_text), 10, 430, 10, rl.BLACK)

    rl.UnloadShader(shader)
    return 0
