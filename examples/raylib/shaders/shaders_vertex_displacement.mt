module examples.raylib.shaders.shaders_vertex_displacement

import std.c.raylib as rl
import std.c.rlgl as rlgl

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const shader_vertex_path_format: cstr = c"../resources/shaders/glsl%i/vertex_displacement.vs"
const shader_fragment_path_format: cstr = c"../resources/shaders/glsl%i/vertex_displacement.fs"
const perlin_noise_uniform_name: cstr = c"perlinNoiseMap"
const time_uniform_name: cstr = c"time"
const title_text: cstr = c"Vertex displacement"
const window_title: cstr = c"raylib [shaders] example - vertex displacement"


def set_model_shader(model: ptr[rl.Model], shader: rl.Shader) -> void:
    unsafe:
        model.materials[0].shader = shader


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 20.0, y = 5.0, z = -20.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 60.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let shader = rl.LoadShader(
        rl.TextFormat(shader_vertex_path_format, glsl_version),
        rl.TextFormat(shader_fragment_path_format, glsl_version),
    )
    defer rl.UnloadShader(shader)

    let perlin_noise_image = rl.GenImagePerlinNoise(512, 512, 0, 0, 1.0)
    defer rl.UnloadImage(perlin_noise_image)
    let perlin_noise_map = rl.LoadTextureFromImage(perlin_noise_image)
    defer rl.UnloadTexture(perlin_noise_map)

    let perlin_noise_map_loc = rl.GetShaderLocation(shader, perlin_noise_uniform_name)
    rlgl.rlEnableShader(shader.id)
    rlgl.rlActiveTextureSlot(1)
    rlgl.rlEnableTexture(perlin_noise_map.id)
    rlgl.rlSetUniformSampler(perlin_noise_map_loc, 1)

    let plane_mesh = rl.GenMeshPlane(50.0, 50.0, 50, 50)
    var plane_model = rl.LoadModelFromMesh(plane_mesh)
    defer rl.UnloadModel(plane_model)
    set_model_shader(ptr_of(plane_model), shader)

    let plane_position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
    let time_loc = rl.GetShaderLocation(shader, time_uniform_name)
    var time: f32 = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(camera), rl.CameraMode.CAMERA_FREE)

        time += rl.GetFrameTime()
        rl.SetShaderValue(shader, time_loc, ptr_of(time), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode3D(camera)
        rl.BeginShaderMode(shader)
        rl.DrawModel(plane_model, plane_position, 1.0, rl.WHITE)
        rl.EndShaderMode()
        rl.EndMode3D()

        rl.DrawText(title_text, 10, 10, 20, rl.DARKGRAY)
        rl.DrawFPS(10, 40)

    return 0
