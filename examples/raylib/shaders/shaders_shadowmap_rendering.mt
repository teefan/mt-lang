module examples.raylib.shaders.shaders_shadowmap_rendering

import std.c.raylib as rl
import std.c.rlgl as rlgl
import std.raylib.math as rm

const glsl_version: i32 = 330
const shadowmap_resolution: i32 = 1024
const screen_width: i32 = 800
const screen_height: i32 = 450
const depth_texture_format: i32 = 19
const window_title: cstr = c"raylib [shaders] example - shadowmap rendering"
const shadowmap_vertex_shader_path_format: cstr = c"../resources/shaders/glsl%i/shadowmap.vs"
const shadowmap_fragment_shader_path_format: cstr = c"../resources/shaders/glsl%i/shadowmap.fs"
const robot_model_path: cstr = c"../resources/models/robot.glb"
const view_pos_uniform_name: cstr = c"viewPos"
const light_dir_uniform_name: cstr = c"lightDir"
const light_color_uniform_name: cstr = c"lightColor"
const ambient_uniform_name: cstr = c"ambient"
const light_vp_uniform_name: cstr = c"lightVP"
const shadow_map_uniform_name: cstr = c"shadowMap"
const shadow_map_resolution_uniform_name: cstr = c"shadowMapResolution"
const use_keys_text: cstr = c"Use the arrow keys to rotate the light!"
const footer_text: cstr = c"Shadows in raylib using the shadowmapping algorithm!"
const screenshot_path: cstr = c"shaders_shadowmap.png"

def raylib_matrix(mat: rlgl.Matrix) -> rl.Matrix:
    return rl.Matrix(
        m0 = mat.m0,
        m4 = mat.m4,
        m8 = mat.m8,
        m12 = mat.m12,
        m1 = mat.m1,
        m5 = mat.m5,
        m9 = mat.m9,
        m13 = mat.m13,
        m2 = mat.m2,
        m6 = mat.m6,
        m10 = mat.m10,
        m14 = mat.m14,
        m3 = mat.m3,
        m7 = mat.m7,
        m11 = mat.m11,
        m15 = mat.m15,
    )

def set_model_shader(model: ptr[rl.Model], shader: rl.Shader) -> void:
    unsafe:
        model.materials[0].shader = shader

def set_all_model_shaders(model: ptr[rl.Model], shader: rl.Shader) -> void:
    unsafe:
        for index in range(0, model.materialCount):
            model.materials[index].shader = shader

def load_shadowmap_render_texture(width: i32, height: i32) -> rl.RenderTexture2D:
    var target = zero[rl.RenderTexture2D]()
    target.id = rlgl.rlLoadFramebuffer()
    target.texture.width = width
    target.texture.height = height

    if target.id > 0:
        rlgl.rlEnableFramebuffer(target.id)

        target.depth.id = rlgl.rlLoadTextureDepth(width, height, false)
        target.depth.width = width
        target.depth.height = height
        target.depth.format = depth_texture_format
        target.depth.mipmaps = 1

        rlgl.rlFramebufferAttach(
            target.id,
            target.depth.id,
            i32<-rlgl.rlFramebufferAttachType.RL_ATTACHMENT_DEPTH,
            i32<-rlgl.rlFramebufferAttachTextureType.RL_ATTACHMENT_TEXTURE2D,
            0,
        )

        rlgl.rlFramebufferComplete(target.id)
        rlgl.rlDisableFramebuffer()

    return target

def unload_shadowmap_render_texture(target: rl.RenderTexture2D) -> void:
    if target.id > 0:
        rlgl.rlUnloadFramebuffer(target.id)

def draw_scene(cube: rl.Model, robot: rl.Model) -> void:
    rl.DrawModelEx(cube, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector3(x = 0.0, y = 1.0, z = 0.0), 0.0, rl.Vector3(x = 10.0, y = 1.0, z = 10.0), rl.BLUE)
    rl.DrawModelEx(cube, rl.Vector3(x = 1.5, y = 1.0, z = -1.5), rl.Vector3(x = 0.0, y = 1.0, z = 0.0), 0.0, rl.Vector3(x = 1.0, y = 1.0, z = 1.0), rl.WHITE)
    rl.DrawModelEx(robot, rl.Vector3(x = 0.0, y = 0.5, z = 0.0), rl.Vector3(x = 0.0, y = 1.0, z = 0.0), 0.0, rl.Vector3(x = 1.0, y = 1.0, z = 1.0), rl.RED)

def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 10.0, y = 10.0, z = 10.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
    )

    var shadow_shader = rl.LoadShader(
        rl.TextFormat(shadowmap_vertex_shader_path_format, glsl_version),
        rl.TextFormat(shadowmap_fragment_shader_path_format, glsl_version),
    )
    defer rl.UnloadShader(shadow_shader)

    let view_loc = rl.GetShaderLocation(shadow_shader, view_pos_uniform_name)
    unsafe:
        shadow_shader.locs[i32<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW] = view_loc

    var light_dir = rl.Vector3(x = 0.35, y = -1.0, z = -0.35).normalize()
    let light_dir_loc = rl.GetShaderLocation(shadow_shader, light_dir_uniform_name)
    var light_color_normalized = rl.ColorNormalize(rl.WHITE)
    let light_col_loc = rl.GetShaderLocation(shadow_shader, light_color_uniform_name)
    rl.SetShaderValue(shadow_shader, light_dir_loc, ptr_of(ref_of(light_dir)), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)
    rl.SetShaderValue(shadow_shader, light_col_loc, ptr_of(ref_of(light_color_normalized)), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)

    let ambient_loc = rl.GetShaderLocation(shadow_shader, ambient_uniform_name)
    var ambient = array[f32, 4](0.1, 0.1, 0.1, 1.0)
    rl.SetShaderValue(shadow_shader, ambient_loc, ptr_of(ref_of(ambient[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)
    let light_vp_loc = rl.GetShaderLocation(shadow_shader, light_vp_uniform_name)
    let shadow_map_loc = rl.GetShaderLocation(shadow_shader, shadow_map_uniform_name)
    var shadow_map_resolution_value = shadowmap_resolution
    rl.SetShaderValue(shadow_shader, rl.GetShaderLocation(shadow_shader, shadow_map_resolution_uniform_name), ptr_of(ref_of(shadow_map_resolution_value)), rl.ShaderUniformDataType.SHADER_UNIFORM_INT)

    var cube = rl.LoadModelFromMesh(rl.GenMeshCube(1.0, 1.0, 1.0))
    defer rl.UnloadModel(cube)
    set_model_shader(ptr_of(ref_of(cube)), shadow_shader)

    var robot = rl.LoadModel(robot_model_path)
    defer rl.UnloadModel(robot)
    set_all_model_shaders(ptr_of(ref_of(robot)), shadow_shader)

    var anim_count = 0
    let anims = rl.LoadModelAnimations(robot_model_path, ptr_of(ref_of(anim_count)))
    defer rl.UnloadModelAnimations(anims, anim_count)
    var anim = zero[rl.ModelAnimation]()
    unsafe:
        anim = anims[0]

    let shadow_map = load_shadowmap_render_texture(shadowmap_resolution, shadowmap_resolution)
    defer unload_shadowmap_render_texture(shadow_map)

    var light_camera = rl.Camera3D(
        position = light_dir.scale(-15.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        projection = rl.CameraProjection.CAMERA_ORTHOGRAPHIC,
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 20.0,
    )

    var frame_counter = 0
    var light_view = zero[rl.Matrix]()
    var light_proj = zero[rl.Matrix]()
    var light_view_proj = zero[rl.Matrix]()
    var texture_active_slot = 10

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let delta_time = rl.GetFrameTime()

        var camera_pos = rl.Vector3(x = camera.position.x, y = camera.position.y, z = camera.position.z)
        rl.SetShaderValue(shadow_shader, view_loc, ptr_of(ref_of(camera_pos)), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)
        rl.UpdateCamera(ptr_of(ref_of(camera)), rl.CameraMode.CAMERA_ORBITAL)

        frame_counter += 1
        frame_counter %= anim.keyframeCount
        rl.UpdateModelAnimation(robot, anim, f32<-frame_counter)

        let camera_speed: f32 = 0.05
        if rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT):
            if light_dir.x < 0.6:
                light_dir.x += camera_speed * 60.0 * delta_time
        if rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT):
            if light_dir.x > -0.6:
                light_dir.x -= camera_speed * 60.0 * delta_time
        if rl.IsKeyDown(rl.KeyboardKey.KEY_UP):
            if light_dir.z < 0.6:
                light_dir.z += camera_speed * 60.0 * delta_time
        if rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN):
            if light_dir.z > -0.6:
                light_dir.z -= camera_speed * 60.0 * delta_time

        light_dir = light_dir.normalize()
        light_camera.position = light_dir.scale(-15.0)
        rl.SetShaderValue(shadow_shader, light_dir_loc, ptr_of(ref_of(light_dir)), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)

        rl.BeginTextureMode(shadow_map)
        rl.ClearBackground(rl.WHITE)
        rl.BeginMode3D(light_camera)
        light_view = raylib_matrix(rlgl.rlGetMatrixModelview())
        light_proj = raylib_matrix(rlgl.rlGetMatrixProjection())
        draw_scene(cube, robot)
        rl.EndMode3D()
        rl.EndTextureMode()
        light_view_proj = light_view.multiply(light_proj)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.SetShaderValueMatrix(shadow_shader, light_vp_loc, light_view_proj)
        rlgl.rlEnableShader(shadow_shader.id)
        rlgl.rlActiveTextureSlot(texture_active_slot)
        rlgl.rlEnableTexture(shadow_map.depth.id)
        rlgl.rlSetUniform(shadow_map_loc, ptr_of(ref_of(texture_active_slot)), i32<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT, 1)

        rl.BeginMode3D(camera)
        draw_scene(cube, robot)
        rl.EndMode3D()

        rl.DrawText(use_keys_text, 10, 10, 30, rl.RED)
        rl.DrawText(footer_text, screen_width - 280, screen_height - 20, 10, rl.GRAY)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_F):
            rl.TakeScreenshot(screenshot_path)

    return 0
