module examples.raylib.models.models_loading_vox

import std.c.raylib as rl
import std.c.rlights as lights
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const max_vox_files: i32 = 4
const max_lights: i32 = 4
const glsl_version: i32 = 330
const window_title: cstr = c"raylib [models] example - loading vox"
const model_load_time_format: cstr = c"[%s] Model file loaded in %.3f ms"
const shader_vertex_path_format: cstr = c"../resources/shaders/glsl%i/voxel_lighting.vs"
const shader_fragment_path_format: cstr = c"../resources/shaders/glsl%i/voxel_lighting.fs"
const vox_model_label_format: cstr = c"VOX model file: %s"
const cycle_models_text: cstr = c"- MOUSE LEFT BUTTON: CYCLE VOX MODELS"
const camera_rotate_text: cstr = c"- MOUSE MIDDLE BUTTON: ZOOM OR ROTATE CAMERA"
const camera_move_text: cstr = c"- UP-DOWN-LEFT-RIGHT KEYS: MOVE CAMERA"


def camera_axis_speed(positive: bool, negative: bool) -> f32:
    if positive and not negative:
        return 0.1
    if negative and not positive:
        return -0.1
    return 0.0


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let vox_file_names = array[cstr, max_vox_files](
        c"../resources/models/vox/chr_knight.vox",
        c"../resources/models/vox/chr_sword.vox",
        c"../resources/models/vox/monu9.vox",
        c"../resources/models/vox/fez.vox",
    )

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 10.0, y = 10.0, z = 10.0),
        target = rm.Vector3.zero(),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var models = zero[array[rl.Model, max_vox_files]]()
    for model_index in 0..max_vox_files:
        let load_start_ms = rl.GetTime() * 1000.0
        models[model_index] = rl.LoadModel(vox_file_names[model_index])
        let load_end_ms = rl.GetTime() * 1000.0

        rl.TraceLog(rl.TraceLogLevel.LOG_INFO, model_load_time_format, vox_file_names[model_index], load_end_ms - load_start_ms)

        let bounds = rl.GetModelBoundingBox(models[model_index])
        let center = rl.Vector3(
            x = bounds.min.x + (bounds.max.x - bounds.min.x) / 2.0,
            y = 0.0,
            z = bounds.min.z + (bounds.max.z - bounds.min.z) / 2.0,
        )
        models[model_index].transform = rm.Matrix.translate(-center.x, 0.0, -center.z)

    var current_model = 0
    let model_pos = rm.Vector3.zero()

    var shader = rl.LoadShader(
        rl.TextFormat(shader_vertex_path_format, glsl_version),
        rl.TextFormat(shader_fragment_path_format, glsl_version),
    )
    let view_loc = rl.GetShaderLocation(shader, c"viewPos")
    unsafe:
        shader.locs[i32<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW] = view_loc

    let ambient_loc = rl.GetShaderLocation(shader, c"ambient")
    var ambient = array[f32, 4](0.1, 0.1, 0.1, 1.0)
    unsafe:
        rl.SetShaderValue(shader, ambient_loc, ptr[void]<-ptr_of(ambient[0]), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)

    unsafe:
        for model_index in 0..max_vox_files:
            for material_index in 0..models[model_index].materialCount:
                models[model_index].materials[material_index].shader = shader

    var light_sources = zero[array[lights.Light, max_lights]]()
    light_sources[0] = lights.CreateLight(i32<-lights.LightType.LIGHT_POINT, rl.Vector3(x = -20.0, y = 20.0, z = -20.0), rm.Vector3.zero(), rl.GRAY, shader)
    light_sources[1] = lights.CreateLight(i32<-lights.LightType.LIGHT_POINT, rl.Vector3(x = 20.0, y = -20.0, z = 20.0), rm.Vector3.zero(), rl.GRAY, shader)
    light_sources[2] = lights.CreateLight(i32<-lights.LightType.LIGHT_POINT, rl.Vector3(x = -20.0, y = 20.0, z = 20.0), rm.Vector3.zero(), rl.GRAY, shader)
    light_sources[3] = lights.CreateLight(i32<-lights.LightType.LIGHT_POINT, rl.Vector3(x = 20.0, y = -20.0, z = -20.0), rm.Vector3.zero(), rl.GRAY, shader)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        var camera_rot = rm.Vector3.zero()
        if rl.IsMouseButtonDown(rl.MouseButton.MOUSE_BUTTON_MIDDLE):
            let mouse_delta = rl.GetMouseDelta()
            camera_rot.x = mouse_delta.x * 0.05
            camera_rot.y = mouse_delta.y * 0.05

        let move_forward = camera_axis_speed(
            rl.IsKeyDown(rl.KeyboardKey.KEY_W) or rl.IsKeyDown(rl.KeyboardKey.KEY_UP),
            rl.IsKeyDown(rl.KeyboardKey.KEY_S) or rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN),
        )
        let move_side = camera_axis_speed(
            rl.IsKeyDown(rl.KeyboardKey.KEY_D) or rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT),
            rl.IsKeyDown(rl.KeyboardKey.KEY_A) or rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT),
        )
        rl.UpdateCameraPro(
            ptr_of(camera),
            rl.Vector3(x = move_forward, y = move_side, z = 0.0),
            camera_rot,
            rl.GetMouseWheelMove() * -2.0,
        )

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            current_model = (current_model + 1) % max_vox_files

        var camera_pos = array[f32, 3](camera.position.x, camera.position.y, camera.position.z)
        unsafe:
            rl.SetShaderValue(shader, view_loc, ptr[void]<-ptr_of(camera_pos[0]), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)

        for light_index in 0..max_lights:
            lights.UpdateLightValues(shader, light_sources[light_index])

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode3D(camera)
        rl.DrawModel(models[current_model], model_pos, 1.0, rl.WHITE)
        rl.DrawGrid(10, 1.0)

        for light_index in 0..max_lights:
            if light_sources[light_index].enabled:
                rl.DrawSphereEx(light_sources[light_index].position, 0.2, 8, 8, light_sources[light_index].color)
            else:
                rl.DrawSphereWires(light_sources[light_index].position, 0.2, 8, 8, rl.ColorAlpha(light_sources[light_index].color, 0.3))
        rl.EndMode3D()

        rl.DrawRectangle(10, 40, 340, 70, rl.Fade(rl.SKYBLUE, 0.5))
        rl.DrawRectangleLines(10, 40, 340, 70, rl.Fade(rl.DARKBLUE, 0.5))
        rl.DrawText(cycle_models_text, 20, 50, 10, rl.BLUE)
        rl.DrawText(camera_rotate_text, 20, 70, 10, rl.BLUE)
        rl.DrawText(camera_move_text, 20, 90, 10, rl.BLUE)
        rl.DrawText(rl.TextFormat(vox_model_label_format, rl.GetFileName(vox_file_names[current_model])), 10, 10, 20, rl.GRAY)

    rl.UnloadShader(shader)
    for model_index in 0..max_vox_files:
        rl.UnloadModel(models[model_index])

    return 0
