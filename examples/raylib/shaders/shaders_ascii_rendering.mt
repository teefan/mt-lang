module examples.raylib.shaders.shaders_ascii_rendering

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const fudesumi_path: cstr = c"../resources/fudesumi.png"
const raysan_path: cstr = c"../resources/raysan.png"
const shader_path_format: cstr = c"../resources/shaders/glsl%i/ascii.fs"
const resolution_uniform_name: cstr = c"resolution"
const font_size_uniform_name: cstr = c"fontSize"
const title_format: cstr = c"Ascii effect - FontSize:%2.0f - [Left] -1 [Right] +1 "
const window_title: cstr = c"raylib [shaders] example - ascii rendering"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let fudesumi = rl.LoadTexture(fudesumi_path)
    defer rl.UnloadTexture(fudesumi)

    let raysan = rl.LoadTexture(raysan_path)
    defer rl.UnloadTexture(raysan)

    let shader = rl.LoadShader(zero[cstr?](), rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    let resolution_location = rl.GetShaderLocation(shader, resolution_uniform_name)
    let font_size_location = rl.GetShaderLocation(shader, font_size_uniform_name)

    var font_size: f32 = 9.0
    var resolution = array[f32, 2](f32<-screen_width, f32<-screen_height)
    rl.SetShaderValue(shader, resolution_location, ptr_of(ref_of(resolution[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

    var circle_position = rl.Vector2(x = 40.0, y = f32<-screen_height * 0.5)
    var circle_speed: f32 = 1.0

    let target = rl.LoadRenderTexture(screen_width, screen_height)
    defer rl.UnloadRenderTexture(target)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        circle_position.x += circle_speed
        if circle_position.x > 200.0 or circle_position.x < 40.0:
            circle_speed *= -1.0

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT) and font_size > 9.0:
            font_size -= 1.0
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT) and font_size < 15.0:
            font_size += 1.0

        rl.SetShaderValue(shader, font_size_location, ptr_of(ref_of(font_size)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

        rl.BeginTextureMode(target)
        rl.ClearBackground(rl.WHITE)
        rl.DrawTexture(fudesumi, 500, -30, rl.WHITE)
        rl.DrawTextureV(raysan, circle_position, rl.WHITE)
        rl.EndTextureMode()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginShaderMode(shader)
        rl.DrawTextureRec(
            target.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = f32<-target.texture.width, height = -f32<-target.texture.height),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE,
        )
        rl.EndShaderMode()

        rl.DrawRectangle(0, 0, screen_width, 40, rl.BLACK)
        rl.DrawText(rl.TextFormat(title_format, font_size), 120, 10, 20, rl.LIGHTGRAY)
        rl.DrawFPS(10, 10)

    return 0
