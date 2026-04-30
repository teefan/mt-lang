module examples.raylib.shaders.shaders_raymarching_rendering

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const shader_path_format: cstr = c"../resources/shaders/glsl%i/raymarching.fs"
const view_eye_uniform_name: cstr = c"viewEye"
const view_center_uniform_name: cstr = c"viewCenter"
const run_time_uniform_name: cstr = c"runTime"
const resolution_uniform_name: cstr = c"resolution"
const credit_text: cstr = c"(c) Raymarching shader by Inigo Quilez. MIT License."
const window_title: cstr = c"raylib [shaders] example - raymarching rendering"

def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_WINDOW_RESIZABLE)

    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 2.5, y = 2.5, z = 3.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.7),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 65.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let shader = rl.LoadShader(zero[cstr?](), rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    let view_eye_loc = rl.GetShaderLocation(shader, view_eye_uniform_name)
    let view_center_loc = rl.GetShaderLocation(shader, view_center_uniform_name)
    let run_time_loc = rl.GetShaderLocation(shader, run_time_uniform_name)
    let resolution_loc = rl.GetShaderLocation(shader, resolution_uniform_name)

    var resolution = array[f32, 2](f32<-screen_width, f32<-screen_height)
    rl.SetShaderValue(shader, resolution_loc, ptr_of(ref_of(resolution[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

    var run_time: f32 = 0.0

    rl.DisableCursor()
    defer rl.EnableCursor()
    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(ref_of(camera)), rl.CameraMode.CAMERA_FIRST_PERSON)

        var camera_pos = array[f32, 3](camera.position.x, camera.position.y, camera.position.z)
        var camera_target = array[f32, 3](camera.target.x, camera.target.y, camera.target.z)

        run_time += rl.GetFrameTime()

        rl.SetShaderValue(shader, view_eye_loc, ptr_of(ref_of(camera_pos[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)
        rl.SetShaderValue(shader, view_center_loc, ptr_of(ref_of(camera_target[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)
        rl.SetShaderValue(shader, run_time_loc, ptr_of(ref_of(run_time)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

        if rl.IsWindowResized():
            resolution[0] = f32<-rl.GetScreenWidth()
            resolution[1] = f32<-rl.GetScreenHeight()
            rl.SetShaderValue(shader, resolution_loc, ptr_of(ref_of(resolution[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginShaderMode(shader)
        rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), rl.WHITE)
        rl.EndShaderMode()

        rl.DrawText(credit_text, rl.GetScreenWidth() - 280, rl.GetScreenHeight() - 20, 10, rl.BLACK)

    return 0
