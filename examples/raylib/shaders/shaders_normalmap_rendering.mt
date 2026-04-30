module examples.raylib.shaders.shaders_normalmap_rendering

import std.c.raylib as rl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const model_path: cstr = c"../resources/models/plane.glb"
const diffuse_texture_path: cstr = c"../resources/tiles_diffuse.png"
const normal_texture_path: cstr = c"../resources/tiles_normal.png"
const shader_vertex_path_format: cstr = c"../resources/shaders/glsl%i/normalmap.vs"
const shader_fragment_path_format: cstr = c"../resources/shaders/glsl%i/normalmap.fs"
const normal_map_uniform_name: cstr = c"normalMap"
const view_pos_uniform_name: cstr = c"viewPos"
const light_pos_uniform_name: cstr = c"lightPos"
const specular_exponent_uniform_name: cstr = c"specularExponent"
const use_normal_map_uniform_name: cstr = c"useNormalMap"
const normal_map_toggle_format: cstr = c"Use key [N] to toggle normal map: %s"
const light_move_text: cstr = c"Use keys [W][A][S][D] to move the light"
const specular_change_text: cstr = c"Use keys [Up][Down] to change specular exponent"
const specular_exponent_format: cstr = c"Specular Exponent: %.2f"
const window_title: cstr = c"raylib [shaders] example - normalmap rendering"

def set_model_shader(model: ptr[rl.Model], shader: rl.Shader) -> void:
    unsafe:
        deref(model).materials[0].shader = shader

def rotate_y(angle: f32) -> rl.Matrix:
    let cosy = rm.cos(angle)
    let siny = rm.sin(angle)
    return rl.Matrix(
        m0 = cosy,
        m4 = 0.0,
        m8 = -siny,
        m12 = 0.0,
        m1 = 0.0,
        m5 = 1.0,
        m9 = 0.0,
        m13 = 0.0,
        m2 = siny,
        m6 = 0.0,
        m10 = cosy,
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
        position = rl.Vector3(x = 0.0, y = 2.0, z = -4.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var shader = rl.LoadShader(
        rl.TextFormat(shader_vertex_path_format, glsl_version),
        rl.TextFormat(shader_fragment_path_format, glsl_version),
    )
    defer rl.UnloadShader(shader)

    let normal_map_loc = rl.GetShaderLocation(shader, normal_map_uniform_name)
    let view_loc = rl.GetShaderLocation(shader, view_pos_uniform_name)
    unsafe:
        shader.locs[i32<-rl.ShaderLocationIndex.SHADER_LOC_MAP_NORMAL] = normal_map_loc
        shader.locs[i32<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW] = view_loc

    let light_pos_loc = rl.GetShaderLocation(shader, light_pos_uniform_name)

    var plane = rl.LoadModel(model_path)
    defer rl.UnloadModel(plane)
    set_model_shader(raw(addr(plane)), shader)

    var diffuse_texture = rl.LoadTexture(diffuse_texture_path)
    defer rl.UnloadTexture(diffuse_texture)
    var normal_texture = rl.LoadTexture(normal_texture_path)
    defer rl.UnloadTexture(normal_texture)

    rl.GenTextureMipmaps(raw(addr(diffuse_texture)))
    rl.GenTextureMipmaps(raw(addr(normal_texture)))
    rl.SetTextureFilter(diffuse_texture, rl.TextureFilter.TEXTURE_FILTER_TRILINEAR)
    rl.SetTextureFilter(normal_texture, rl.TextureFilter.TEXTURE_FILTER_TRILINEAR)
    rl.SetMaterialTexture(plane.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, diffuse_texture)
    rl.SetMaterialTexture(plane.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_NORMAL, normal_texture)

    var light_position = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
    let light_speed: f32 = 3.0
    let specular_rate: f32 = 40.0
    var specular_exponent: f32 = 8.0
    let specular_exponent_loc = rl.GetShaderLocation(shader, specular_exponent_uniform_name)

    var use_normal_map = 1
    let use_normal_map_loc = rl.GetShaderLocation(shader, use_normal_map_uniform_name)
    let text_y_offset = 24

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        var direction = rm.Vector3.zero()
        if rl.IsKeyDown(rl.KeyboardKey.KEY_W):
            direction = direction.add(rl.Vector3(x = 0.0, y = 0.0, z = 1.0))
        if rl.IsKeyDown(rl.KeyboardKey.KEY_S):
            direction = direction.add(rl.Vector3(x = 0.0, y = 0.0, z = -1.0))
        if rl.IsKeyDown(rl.KeyboardKey.KEY_D):
            direction = direction.add(rl.Vector3(x = -1.0, y = 0.0, z = 0.0))
        if rl.IsKeyDown(rl.KeyboardKey.KEY_A):
            direction = direction.add(rl.Vector3(x = 1.0, y = 0.0, z = 0.0))

        direction = direction.normalize()
        light_position = light_position.add(direction.scale(rl.GetFrameTime() * light_speed))

        if rl.IsKeyDown(rl.KeyboardKey.KEY_UP):
            specular_exponent = rm.clamp(specular_exponent + specular_rate * rl.GetFrameTime(), 2.0, 128.0)
        if rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN):
            specular_exponent = rm.clamp(specular_exponent - specular_rate * rl.GetFrameTime(), 2.0, 128.0)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_N):
            use_normal_map = 1 - use_normal_map

        plane.transform = rotate_y(f32<-rl.GetTime() * 0.5)

        var light_pos = array[f32, 3](light_position.x, light_position.y, light_position.z)
        rl.SetShaderValue(shader, light_pos_loc, raw(addr(light_pos[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)

        var camera_pos = array[f32, 3](camera.position.x, camera.position.y, camera.position.z)
        rl.SetShaderValue(shader, view_loc, raw(addr(camera_pos[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)

        rl.SetShaderValue(shader, specular_exponent_loc, raw(addr(specular_exponent)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.SetShaderValue(shader, use_normal_map_loc, raw(addr(use_normal_map)), rl.ShaderUniformDataType.SHADER_UNIFORM_INT)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode3D(camera)
        rl.BeginShaderMode(shader)
        rl.DrawModel(plane, rm.Vector3.zero(), 2.0, rl.WHITE)
        rl.EndShaderMode()
        rl.DrawSphereWires(light_position, 0.2, 8, 8, rl.ORANGE)
        rl.EndMode3D()

        let toggle_color = if use_normal_map != 0 then rl.DARKGREEN else rl.RED
        let toggle_text = if use_normal_map != 0 then c"On" else c"Off"
        rl.DrawText(rl.TextFormat(normal_map_toggle_format, toggle_text), 10, 10, 10, toggle_color)
        rl.DrawText(light_move_text, 10, 10 + text_y_offset, 10, rl.BLACK)
        rl.DrawText(specular_change_text, 10, 10 + text_y_offset * 2, 10, rl.BLACK)
        rl.DrawText(rl.TextFormat(specular_exponent_format, specular_exponent), 10, 10 + text_y_offset * 3, 10, rl.BLUE)
        rl.DrawFPS(screen_width - 90, 10)

    return 0
