module examples.raylib.shaders.shaders_basic_lighting

import std.c.raylib as rl
import std.c.rlights as lights
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const shader_vertex_path_format: cstr = c"../resources/shaders/glsl%i/lighting.vs"
const shader_fragment_path_format: cstr = c"../resources/shaders/glsl%i/lighting.fs"
const view_pos_uniform_name: cstr = c"viewPos"
const ambient_uniform_name: cstr = c"ambient"
const help_text: cstr = c"Use keys [Y][R][G][B] to toggle lights"
const window_title: cstr = c"raylib [shaders] example - basic lighting"

def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 2.0, y = 4.0, z = 6.0),
        target = rl.Vector3(x = 0.0, y = 0.5, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var shader = rl.LoadShader(
        rl.TextFormat(shader_vertex_path_format, glsl_version),
        rl.TextFormat(shader_fragment_path_format, glsl_version),
    )
    defer rl.UnloadShader(shader)

    let view_loc = rl.GetShaderLocation(shader, view_pos_uniform_name)
    unsafe:
        shader.locs[i32<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW] = view_loc

    let ambient_loc = rl.GetShaderLocation(shader, ambient_uniform_name)
    var ambient = array[f32, 4](0.1, 0.1, 0.1, 1.0)
    rl.SetShaderValue(shader, ambient_loc, raw(addr(ambient[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)

    var light_sources = zero[array[lights.Light, 4]]()
    light_sources[0] = lights.CreateLight(i32<-lights.LightType.LIGHT_POINT, rl.Vector3(x = -2.0, y = 1.0, z = -2.0), rm.Vector3.zero(), rl.YELLOW, shader)
    light_sources[1] = lights.CreateLight(i32<-lights.LightType.LIGHT_POINT, rl.Vector3(x = 2.0, y = 1.0, z = 2.0), rm.Vector3.zero(), rl.RED, shader)
    light_sources[2] = lights.CreateLight(i32<-lights.LightType.LIGHT_POINT, rl.Vector3(x = -2.0, y = 1.0, z = 2.0), rm.Vector3.zero(), rl.GREEN, shader)
    light_sources[3] = lights.CreateLight(i32<-lights.LightType.LIGHT_POINT, rl.Vector3(x = 2.0, y = 1.0, z = -2.0), rm.Vector3.zero(), rl.BLUE, shader)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(raw(addr(camera)), rl.CameraMode.CAMERA_ORBITAL)

        var camera_pos = array[f32, 3](camera.position.x, camera.position.y, camera.position.z)
        rl.SetShaderValue(
            shader,
            view_loc,
            raw(addr(camera_pos[0])),
            rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3,
        )

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_Y):
            light_sources[0].enabled = not light_sources[0].enabled
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_R):
            light_sources[1].enabled = not light_sources[1].enabled
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_G):
            light_sources[2].enabled = not light_sources[2].enabled
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_B):
            light_sources[3].enabled = not light_sources[3].enabled

        for light_index in range(0, lights.MAX_LIGHTS):
            lights.UpdateLightValues(shader, light_sources[light_index])

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode3D(camera)
        rl.BeginShaderMode(shader)
        rl.DrawPlane(rm.Vector3.zero(), rl.Vector2(x = 10.0, y = 10.0), rl.WHITE)
        rl.DrawCube(rm.Vector3.zero(), 2.0, 4.0, 2.0, rl.WHITE)
        rl.EndShaderMode()

        for light_index in range(0, lights.MAX_LIGHTS):
            if light_sources[light_index].enabled:
                rl.DrawSphereEx(light_sources[light_index].position, 0.2, 8, 8, light_sources[light_index].color)
            else:
                rl.DrawSphereWires(light_sources[light_index].position, 0.2, 8, 8, rl.ColorAlpha(light_sources[light_index].color, 0.3))

        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()

        rl.DrawFPS(10, 10)
        rl.DrawText(help_text, 10, 40, 20, rl.DARKGRAY)

    return 0
