module examples.raylib.shaders.shaders_fog_rendering

import std.c.raylib as rl
import std.c.rlights as lights
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const texture_path: cstr = c"resources/texel_checker.png"
const shader_vertex_path_format: cstr = c"resources/shaders/glsl%i/lighting.vs"
const shader_fragment_path_format: cstr = c"resources/shaders/glsl%i/fog.fs"
const matrix_model_uniform_name: cstr = c"matModel"
const view_pos_uniform_name: cstr = c"viewPos"
const ambient_uniform_name: cstr = c"ambient"
const fog_color_uniform_name: cstr = c"fogColor"
const fog_density_uniform_name: cstr = c"fogDensity"
const fog_density_format: cstr = c"Use KEY_UP/KEY_DOWN to change fog density [%.2f]"
const window_title: cstr = c"raylib [shaders] example - fog rendering"

def set_model_shader(model: ptr[rl.Model], shader: rl.Shader) -> void:
    unsafe:
        deref(model).materials[0].shader = shader

def rotate_x(angle: f32) -> rl.Matrix:
    let cosx = rm.cos(angle)
    let sinx = rm.sin(angle)
    return rl.Matrix(
        m0 = 1.0,
        m4 = 0.0,
        m8 = 0.0,
        m12 = 0.0,
        m1 = 0.0,
        m5 = cosx,
        m9 = sinx,
        m13 = 0.0,
        m2 = 0.0,
        m6 = -sinx,
        m10 = cosx,
        m14 = 0.0,
        m3 = 0.0,
        m7 = 0.0,
        m11 = 0.0,
        m15 = 1.0,
    )

def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 2.0, y = 2.0, z = 6.0),
        target = rl.Vector3(x = 0.0, y = 0.5, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var model_a = rl.LoadModelFromMesh(rl.GenMeshTorus(0.4, 1.0, 16, 32))
    defer rl.UnloadModel(model_a)
    var model_b = rl.LoadModelFromMesh(rl.GenMeshCube(1.0, 1.0, 1.0))
    defer rl.UnloadModel(model_b)
    var model_c = rl.LoadModelFromMesh(rl.GenMeshSphere(0.5, 32, 32))
    defer rl.UnloadModel(model_c)

    let texture = rl.LoadTexture(texture_path)
    defer rl.UnloadTexture(texture)
    rl.SetMaterialTexture(model_a.materials, cast[i32](rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO), texture)
    rl.SetMaterialTexture(model_b.materials, cast[i32](rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO), texture)
    rl.SetMaterialTexture(model_c.materials, cast[i32](rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO), texture)

    var shader = rl.LoadShader(
        rl.TextFormat(shader_vertex_path_format, glsl_version),
        rl.TextFormat(shader_fragment_path_format, glsl_version),
    )
    defer rl.UnloadShader(shader)

    let matrix_model_loc = rl.GetShaderLocation(shader, matrix_model_uniform_name)
    let view_loc = rl.GetShaderLocation(shader, view_pos_uniform_name)
    unsafe:
        shader.locs[cast[i32](rl.ShaderLocationIndex.SHADER_LOC_MATRIX_MODEL)] = matrix_model_loc
        shader.locs[cast[i32](rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW)] = view_loc

    let ambient_loc = rl.GetShaderLocation(shader, ambient_uniform_name)
    var ambient = array[f32, 4](0.2, 0.2, 0.2, 1.0)
    rl.SetShaderValue(shader, ambient_loc, raw(addr(ambient[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)

    let fog_color_value = rl.ColorNormalize(rl.GRAY)
    let fog_color_loc = rl.GetShaderLocation(shader, fog_color_uniform_name)
    var fog_color = array[f32, 4](fog_color_value.x, fog_color_value.y, fog_color_value.z, fog_color_value.w)
    rl.SetShaderValue(shader, fog_color_loc, raw(addr(fog_color[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)

    var fog_density: f32 = 0.15
    let fog_density_step: f32 = 0.001
    let fog_density_loc = rl.GetShaderLocation(shader, fog_density_uniform_name)
    rl.SetShaderValue(shader, fog_density_loc, raw(addr(fog_density)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

    set_model_shader(raw(addr(model_a)), shader)
    set_model_shader(raw(addr(model_b)), shader)
    set_model_shader(raw(addr(model_c)), shader)

    lights.CreateLight(cast[i32](lights.LightType.LIGHT_POINT), rl.Vector3(x = 0.0, y = 2.0, z = 6.0), rm.Vector3.zero(), rl.WHITE, shader)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(raw(addr(camera)), rl.CameraMode.CAMERA_ORBITAL)

        if rl.IsKeyDown(rl.KeyboardKey.KEY_UP):
            fog_density += fog_density_step
            if fog_density > 1.0:
                fog_density = 1.0

        if rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN):
            fog_density -= fog_density_step
            if fog_density < 0.0:
                fog_density = 0.0

        rl.SetShaderValue(shader, fog_density_loc, raw(addr(fog_density)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

        model_a.transform = model_a.transform.multiply(rotate_x(-0.025))
        model_a.transform = model_a.transform.multiply(rm.Matrix.rotate_z(0.012))

        var camera_pos = array[f32, 3](camera.position.x, camera.position.y, camera.position.z)
        rl.SetShaderValue(shader, view_loc, raw(addr(camera_pos[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.GRAY)

        rl.BeginMode3D(camera)
        rl.DrawModel(model_a, rm.Vector3.zero(), 1.0, rl.WHITE)
        rl.DrawModel(model_b, rl.Vector3(x = -2.6, y = 0.0, z = 0.0), 1.0, rl.WHITE)
        rl.DrawModel(model_c, rl.Vector3(x = 2.6, y = 0.0, z = 0.0), 1.0, rl.WHITE)

        var torus_x = -20
        while torus_x < 20:
            rl.DrawModel(model_a, rl.Vector3(x = cast[f32](torus_x), y = 0.0, z = 2.0), 1.0, rl.WHITE)
            torus_x += 2
        rl.EndMode3D()

        rl.DrawText(rl.TextFormat(fog_density_format, fog_density), 10, 10, 20, rl.RAYWHITE)

    return 0
