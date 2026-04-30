module examples.raylib.shaders.shaders_texture_waves

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const texture_path: cstr = c"../resources/space.png"
const shader_path_format: cstr = c"../resources/shaders/glsl%i/wave.fs"
const size_uniform_name: cstr = c"size"
const seconds_uniform_name: cstr = c"seconds"
const freq_x_uniform_name: cstr = c"freqX"
const freq_y_uniform_name: cstr = c"freqY"
const amp_x_uniform_name: cstr = c"ampX"
const amp_y_uniform_name: cstr = c"ampY"
const speed_x_uniform_name: cstr = c"speedX"
const speed_y_uniform_name: cstr = c"speedY"
const window_title: cstr = c"raylib [shaders] example - texture waves"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let texture = rl.LoadTexture(texture_path)
    defer rl.UnloadTexture(texture)

    let shader = rl.LoadShader(zero[cstr?](), rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    let seconds_loc = rl.GetShaderLocation(shader, seconds_uniform_name)
    let freq_x_loc = rl.GetShaderLocation(shader, freq_x_uniform_name)
    let freq_y_loc = rl.GetShaderLocation(shader, freq_y_uniform_name)
    let amp_x_loc = rl.GetShaderLocation(shader, amp_x_uniform_name)
    let amp_y_loc = rl.GetShaderLocation(shader, amp_y_uniform_name)
    let speed_x_loc = rl.GetShaderLocation(shader, speed_x_uniform_name)
    let speed_y_loc = rl.GetShaderLocation(shader, speed_y_uniform_name)

    var freq_x: f32 = 25.0
    var freq_y: f32 = 25.0
    var amp_x: f32 = 5.0
    var amp_y: f32 = 5.0
    var speed_x: f32 = 8.0
    var speed_y: f32 = 8.0
    var screen_size = array[f32, 2](f32<-rl.GetScreenWidth(), f32<-rl.GetScreenHeight())
    var seconds: f32 = 0.0

    rl.SetShaderValue(shader, rl.GetShaderLocation(shader, size_uniform_name), raw(addr(screen_size[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
    rl.SetShaderValue(shader, freq_x_loc, raw(addr(freq_x)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
    rl.SetShaderValue(shader, freq_y_loc, raw(addr(freq_y)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
    rl.SetShaderValue(shader, amp_x_loc, raw(addr(amp_x)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
    rl.SetShaderValue(shader, amp_y_loc, raw(addr(amp_y)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
    rl.SetShaderValue(shader, speed_x_loc, raw(addr(speed_x)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
    rl.SetShaderValue(shader, speed_y_loc, raw(addr(speed_y)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        seconds += rl.GetFrameTime()
        rl.SetShaderValue(shader, seconds_loc, raw(addr(seconds)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginShaderMode(shader)
        rl.DrawTexture(texture, 0, 0, rl.WHITE)
        rl.DrawTexture(texture, texture.width, 0, rl.WHITE)
        rl.EndShaderMode()

    return 0
