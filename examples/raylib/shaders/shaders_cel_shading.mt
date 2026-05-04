module examples.raylib.shaders.shaders_cel_shading

import std.c.raylib as rl
import std.c.rlgl as rlgl
import std.c.rlights as lights
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const model_path: cstr = c"../resources/models/old_car_new.glb"
const cel_vertex_path_format: cstr = c"../resources/shaders/glsl%i/cel.vs"
const cel_fragment_path_format: cstr = c"../resources/shaders/glsl%i/cel.fs"
const outline_vertex_path_format: cstr = c"../resources/shaders/glsl%i/outline_hull.vs"
const outline_fragment_path_format: cstr = c"../resources/shaders/glsl%i/outline_hull.fs"
const view_pos_uniform_name: cstr = c"viewPos"
const num_bands_uniform_name: cstr = c"numBands"
const outline_thickness_uniform_name: cstr = c"outlineThickness"
const cel_status_format: cstr = c"Cel: %s  [Z]"
const outline_status_format: cstr = c"Outline: %s  [C]"
const bands_status_format: cstr = c"Bands: %.0f  [Q/E]"
const window_title: cstr = c"raylib [shaders] example - cel shading"


def model_shader(model: ptr[rl.Model]) -> rl.Shader:
    unsafe:
        return model.materials[0].shader


def set_model_shader(model: ptr[rl.Model], shader: rl.Shader) -> void:
    unsafe:
        model.materials[0].shader = shader


def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 9.0, y = 6.0, z = 9.0),
        target = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var model = rl.LoadModel(model_path)
    defer rl.UnloadModel(model)

    var cel_shader = rl.LoadShader(
        rl.TextFormat(cel_vertex_path_format, glsl_version),
        rl.TextFormat(cel_fragment_path_format, glsl_version),
    )
    defer rl.UnloadShader(cel_shader)

    let view_loc = rl.GetShaderLocation(cel_shader, view_pos_uniform_name)
    unsafe:
        cel_shader.locs[i32<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW] = view_loc

    let default_shader = model_shader(ptr_of(model))
    set_model_shader(ptr_of(model), cel_shader)

    var num_bands: f32 = 10.0
    let num_bands_loc = rl.GetShaderLocation(cel_shader, num_bands_uniform_name)
    rl.SetShaderValue(cel_shader, num_bands_loc, ptr_of(num_bands), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

    let outline_shader = rl.LoadShader(
        rl.TextFormat(outline_vertex_path_format, glsl_version),
        rl.TextFormat(outline_fragment_path_format, glsl_version),
    )
    defer rl.UnloadShader(outline_shader)
    let outline_thickness_loc = rl.GetShaderLocation(outline_shader, outline_thickness_uniform_name)

    var light_sources = zero[array[lights.Light, 4]]
    light_sources[0] = lights.CreateLight(i32<-lights.LightType.LIGHT_DIRECTIONAL, rl.Vector3(x = 50.0, y = 50.0, z = 50.0), rm.Vector3.zero(), rl.WHITE, cel_shader)

    var cel_enabled = true
    var outline_enabled = true
    let light_rotation_speed: f32 = 0.3
    let light_radius: f32 = 5.0
    var outline_thickness: f32 = 0.005

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(camera), rl.CameraMode.CAMERA_ORBITAL)

        var camera_pos = array[f32, 3](camera.position.x, camera.position.y, camera.position.z)
        rl.SetShaderValue(cel_shader, view_loc, ptr_of(camera_pos[0]), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_Z):
            cel_enabled = not cel_enabled
            if cel_enabled:
                set_model_shader(ptr_of(model), cel_shader)
            else:
                set_model_shader(ptr_of(model), default_shader)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_C):
            outline_enabled = not outline_enabled

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_E) or rl.IsKeyPressedRepeat(rl.KeyboardKey.KEY_E):
            num_bands = rm.clamp(num_bands + 1.0, 2.0, 20.0)
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_Q) or rl.IsKeyPressedRepeat(rl.KeyboardKey.KEY_Q):
            num_bands = rm.clamp(num_bands - 1.0, 2.0, 20.0)
        rl.SetShaderValue(cel_shader, num_bands_loc, ptr_of(num_bands), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

        let time = f32<-rl.GetTime()
        light_sources[0].position = rl.Vector3(
            x = rm.sin(-time * light_rotation_speed) * light_radius,
            y = 5.0,
            z = rm.cos(-time * light_rotation_speed) * light_radius,
        )

        for light_index in 0..lights.MAX_LIGHTS:
            lights.UpdateLightValues(cel_shader, light_sources[light_index])

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode3D(camera)
        if outline_enabled:
            rl.SetShaderValue(outline_shader, outline_thickness_loc, ptr_of(outline_thickness), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
            rlgl.rlSetCullFace(i32<-rlgl.rlCullMode.RL_CULL_FACE_FRONT)
            set_model_shader(ptr_of(model), outline_shader)
            rl.DrawModel(model, rm.Vector3.zero(), 0.75, rl.WHITE)

            if cel_enabled:
                set_model_shader(ptr_of(model), cel_shader)
            else:
                set_model_shader(ptr_of(model), default_shader)

            rlgl.rlSetCullFace(i32<-rlgl.rlCullMode.RL_CULL_FACE_BACK)

        rl.DrawModel(model, rm.Vector3.zero(), 0.75, rl.WHITE)
        rl.DrawSphereEx(light_sources[0].position, 0.2, 50, 50, rl.YELLOW)
        rl.DrawGrid(10, 10.0)
        rl.EndMode3D()

        rl.DrawFPS(10, 10)
        rl.DrawText(rl.TextFormat(cel_status_format, if cel_enabled: c"ON" else: c"OFF"), 10, 65, 20, if cel_enabled: rl.DARKGREEN else: rl.DARKGRAY)
        rl.DrawText(rl.TextFormat(outline_status_format, if outline_enabled: c"ON" else: c"OFF"), 10, 90, 20, if outline_enabled: rl.DARKGREEN else: rl.DARKGRAY)
        rl.DrawText(rl.TextFormat(bands_status_format, num_bands), 10, 115, 20, rl.DARKGRAY)

    return 0
