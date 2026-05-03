module examples.raylib.shaders.shaders_deferred_rendering

import std.c.raylib as rl
import std.c.rlgl as rlgl
import std.c.rlights as lights
import std.raylib.math as rm

struct GBuffer:
    framebuffer_id: u32
    position_texture_id: u32
    normal_texture_id: u32
    albedo_spec_texture_id: u32
    depth_renderbuffer_id: u32

enum DeferredMode: i32
    DEFERRED_POSITION = 0
    DEFERRED_NORMAL = 1
    DEFERRED_ALBEDO = 2
    DEFERRED_SHADING = 3

const glsl_version: i32 = 330
const max_cubes: i32 = 30
const screen_width: i32 = 800
const screen_height: i32 = 450
const depth_buffer_bit: i32 = 0x00000100
const pixel_format_r8g8b8a8: i32 = 7
const pixel_format_r16g16b16: i32 = 12
const window_title: cstr = c"raylib [shaders] example - deferred rendering"
const gbuffer_vertex_shader_path_format: cstr = c"../resources/shaders/glsl%i/gbuffer.vs"
const gbuffer_fragment_shader_path_format: cstr = c"../resources/shaders/glsl%i/gbuffer.fs"
const deferred_vertex_shader_path_format: cstr = c"../resources/shaders/glsl%i/deferred_shading.vs"
const deferred_fragment_shader_path_format: cstr = c"../resources/shaders/glsl%i/deferred_shading.fs"
const view_position_uniform_name: cstr = c"viewPosition"
const gposition_uniform_name: cstr = c"gPosition"
const gnormal_uniform_name: cstr = c"gNormal"
const galbedo_spec_uniform_name: cstr = c"gAlbedoSpec"
const final_result_text: cstr = c"FINAL RESULT"
const position_texture_text: cstr = c"POSITION TEXTURE"
const normal_texture_text: cstr = c"NORMAL TEXTURE"
const albedo_texture_text: cstr = c"ALBEDO TEXTURE"
const toggle_lights_text: cstr = c"Toggle lights keys: [Y][R][G][B]"
const switch_textures_text: cstr = c"Switch G-buffer textures: [1][2][3][4]"
const cube_scale: f32 = 0.25


def set_model_shader(model: ptr[rl.Model], shader: rl.Shader) -> void:
    unsafe:
        model.materials[0].shader = shader


def gbuffer_texture(id: u32, width: i32, height: i32) -> rl.Texture:
    return rl.Texture(id = id, width = width, height = height, mipmaps = 1, format = 0)


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 5.0, y = 4.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 60.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var model = rl.LoadModelFromMesh(rl.GenMeshPlane(10.0, 10.0, 3, 3))
    defer rl.UnloadModel(model)
    var cube = rl.LoadModelFromMesh(rl.GenMeshCube(2.0, 2.0, 2.0))
    defer rl.UnloadModel(cube)

    var gbuffer_shader = rl.LoadShader(
        rl.TextFormat(gbuffer_vertex_shader_path_format, glsl_version),
        rl.TextFormat(gbuffer_fragment_shader_path_format, glsl_version),
    )
    defer rl.UnloadShader(gbuffer_shader)

    var deferred_shader = rl.LoadShader(
        rl.TextFormat(deferred_vertex_shader_path_format, glsl_version),
        rl.TextFormat(deferred_fragment_shader_path_format, glsl_version),
    )
    defer rl.UnloadShader(deferred_shader)
    let view_loc = rl.GetShaderLocation(deferred_shader, view_position_uniform_name)
    unsafe:
        deferred_shader.locs[i32<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW] = view_loc

    var gbuffer = zero[GBuffer]()
    gbuffer.framebuffer_id = rlgl.rlLoadFramebuffer()
    rlgl.rlEnableFramebuffer(gbuffer.framebuffer_id)

    gbuffer.position_texture_id = rlgl.rlLoadTexture(null, screen_width, screen_height, pixel_format_r16g16b16, 1)
    gbuffer.normal_texture_id = rlgl.rlLoadTexture(null, screen_width, screen_height, pixel_format_r16g16b16, 1)
    gbuffer.albedo_spec_texture_id = rlgl.rlLoadTexture(null, screen_width, screen_height, pixel_format_r8g8b8a8, 1)

    rlgl.rlActiveDrawBuffers(3)
    rlgl.rlFramebufferAttach(gbuffer.framebuffer_id, gbuffer.position_texture_id, i32<-rlgl.rlFramebufferAttachType.RL_ATTACHMENT_COLOR_CHANNEL0, i32<-rlgl.rlFramebufferAttachTextureType.RL_ATTACHMENT_TEXTURE2D, 0)
    rlgl.rlFramebufferAttach(gbuffer.framebuffer_id, gbuffer.normal_texture_id, i32<-rlgl.rlFramebufferAttachType.RL_ATTACHMENT_COLOR_CHANNEL1, i32<-rlgl.rlFramebufferAttachTextureType.RL_ATTACHMENT_TEXTURE2D, 0)
    rlgl.rlFramebufferAttach(gbuffer.framebuffer_id, gbuffer.albedo_spec_texture_id, i32<-rlgl.rlFramebufferAttachType.RL_ATTACHMENT_COLOR_CHANNEL2, i32<-rlgl.rlFramebufferAttachTextureType.RL_ATTACHMENT_TEXTURE2D, 0)

    gbuffer.depth_renderbuffer_id = rlgl.rlLoadTextureDepth(screen_width, screen_height, true)
    rlgl.rlFramebufferAttach(gbuffer.framebuffer_id, gbuffer.depth_renderbuffer_id, i32<-rlgl.rlFramebufferAttachType.RL_ATTACHMENT_DEPTH, i32<-rlgl.rlFramebufferAttachTextureType.RL_ATTACHMENT_RENDERBUFFER, 0)
    rlgl.rlFramebufferComplete(gbuffer.framebuffer_id)

    rlgl.rlEnableShader(deferred_shader.id)
    var tex_unit_position = 0
    var tex_unit_normal = 1
    var tex_unit_albedo_spec = 2
    rl.SetShaderValue(deferred_shader, rlgl.rlGetLocationUniform(deferred_shader.id, gposition_uniform_name), ptr_of(ref_of(tex_unit_position)), rl.ShaderUniformDataType.SHADER_UNIFORM_SAMPLER2D)
    rl.SetShaderValue(deferred_shader, rlgl.rlGetLocationUniform(deferred_shader.id, gnormal_uniform_name), ptr_of(ref_of(tex_unit_normal)), rl.ShaderUniformDataType.SHADER_UNIFORM_SAMPLER2D)
    rl.SetShaderValue(deferred_shader, rlgl.rlGetLocationUniform(deferred_shader.id, galbedo_spec_uniform_name), ptr_of(ref_of(tex_unit_albedo_spec)), rl.ShaderUniformDataType.SHADER_UNIFORM_SAMPLER2D)
    rlgl.rlDisableShader()

    set_model_shader(ptr_of(ref_of(model)), gbuffer_shader)
    set_model_shader(ptr_of(ref_of(cube)), gbuffer_shader)

    var light_sources = zero[array[lights.Light, 4]]()
    light_sources[0] = lights.CreateLight(i32<-lights.LightType.LIGHT_POINT, rl.Vector3(x = -2.0, y = 1.0, z = -2.0), rm.Vector3.zero(), rl.YELLOW, deferred_shader)
    light_sources[1] = lights.CreateLight(i32<-lights.LightType.LIGHT_POINT, rl.Vector3(x = 2.0, y = 1.0, z = 2.0), rm.Vector3.zero(), rl.RED, deferred_shader)
    light_sources[2] = lights.CreateLight(i32<-lights.LightType.LIGHT_POINT, rl.Vector3(x = -2.0, y = 1.0, z = 2.0), rm.Vector3.zero(), rl.GREEN, deferred_shader)
    light_sources[3] = lights.CreateLight(i32<-lights.LightType.LIGHT_POINT, rl.Vector3(x = 2.0, y = 1.0, z = -2.0), rm.Vector3.zero(), rl.BLUE, deferred_shader)

    var cube_positions = zero[array[rl.Vector3, 30]]()
    var cube_rotations = zero[array[f32, 30]]()
    for index in range(0, max_cubes):
        cube_positions[index] = rl.Vector3(
            x = f32<-rl.GetRandomValue(0, 9) - 5.0,
            y = f32<-rl.GetRandomValue(0, 4),
            z = f32<-rl.GetRandomValue(0, 9) - 5.0,
        )
        cube_rotations[index] = f32<-rl.GetRandomValue(0, 359)

    var mode = i32<-DeferredMode.DEFERRED_SHADING

    rlgl.rlEnableDepthTest()
    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(ref_of(camera)), rl.CameraMode.CAMERA_ORBITAL)

        var camera_pos = array[f32, 3](camera.position.x, camera.position.y, camera.position.z)
        rl.SetShaderValue(deferred_shader, view_loc, ptr_of(ref_of(camera_pos[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_Y):
            light_sources[0].enabled = not light_sources[0].enabled
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_R):
            light_sources[1].enabled = not light_sources[1].enabled
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_G):
            light_sources[2].enabled = not light_sources[2].enabled
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_B):
            light_sources[3].enabled = not light_sources[3].enabled

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_ONE):
            mode = i32<-DeferredMode.DEFERRED_POSITION
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_TWO):
            mode = i32<-DeferredMode.DEFERRED_NORMAL
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_THREE):
            mode = i32<-DeferredMode.DEFERRED_ALBEDO
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_FOUR):
            mode = i32<-DeferredMode.DEFERRED_SHADING

        for index in range(0, lights.MAX_LIGHTS):
            lights.UpdateLightValues(deferred_shader, light_sources[index])

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rlgl.rlEnableFramebuffer(gbuffer.framebuffer_id)
        rlgl.rlClearColor(0, 0, 0, 0)
        rlgl.rlClearScreenBuffers()
        rlgl.rlDisableColorBlend()

        rl.BeginMode3D(camera)
        rlgl.rlEnableShader(gbuffer_shader.id)
        rl.DrawModel(model, rm.Vector3.zero(), 1.0, rl.WHITE)
        rl.DrawModel(cube, rl.Vector3(x = 0.0, y = 1.0, z = 0.0), 1.0, rl.WHITE)
        for index in range(0, max_cubes):
            let position = cube_positions[index]
            rl.DrawModelEx(cube, position, rl.Vector3(x = 1.0, y = 1.0, z = 1.0), cube_rotations[index], rl.Vector3(x = cube_scale, y = cube_scale, z = cube_scale), rl.WHITE)
        rlgl.rlDisableShader()
        rl.EndMode3D()

        rlgl.rlEnableColorBlend()
        rlgl.rlDisableFramebuffer()
        rlgl.rlClearScreenBuffers()

        if mode == i32<-DeferredMode.DEFERRED_SHADING:
            rl.BeginMode3D(camera)
            rlgl.rlDisableColorBlend()
            rlgl.rlEnableShader(deferred_shader.id)
            rlgl.rlActiveTextureSlot(tex_unit_position)
            rlgl.rlEnableTexture(gbuffer.position_texture_id)
            rlgl.rlActiveTextureSlot(tex_unit_normal)
            rlgl.rlEnableTexture(gbuffer.normal_texture_id)
            rlgl.rlActiveTextureSlot(tex_unit_albedo_spec)
            rlgl.rlEnableTexture(gbuffer.albedo_spec_texture_id)
            rlgl.rlLoadDrawQuad()
            rlgl.rlDisableShader()
            rlgl.rlEnableColorBlend()
            rl.EndMode3D()

            rlgl.rlBindFramebuffer(u32<-rlgl.RL_READ_FRAMEBUFFER, gbuffer.framebuffer_id)
            rlgl.rlBindFramebuffer(u32<-rlgl.RL_DRAW_FRAMEBUFFER, 0)
            rlgl.rlBlitFramebuffer(0, 0, screen_width, screen_height, 0, 0, screen_width, screen_height, depth_buffer_bit)
            rlgl.rlDisableFramebuffer()

            rl.BeginMode3D(camera)
            rlgl.rlEnableShader(rlgl.rlGetShaderIdDefault())
            for index in range(0, lights.MAX_LIGHTS):
                if light_sources[index].enabled:
                    rl.DrawSphereEx(light_sources[index].position, 0.2, 8, 8, light_sources[index].color)
                else:
                    rl.DrawSphereWires(light_sources[index].position, 0.2, 8, 8, rl.ColorAlpha(light_sources[index].color, 0.3))
            rlgl.rlDisableShader()
            rl.EndMode3D()

            rl.DrawText(final_result_text, 10, screen_height - 30, 20, rl.DARKGREEN)
        elif mode == i32<-DeferredMode.DEFERRED_POSITION:
            rl.DrawTextureRec(gbuffer_texture(gbuffer.position_texture_id, screen_width, screen_height), rl.Rectangle(x = 0.0, y = 0.0, width = f32<-screen_width, height = -f32<-screen_height), rm.Vector2.zero(), rl.RAYWHITE)
            rl.DrawText(position_texture_text, 10, screen_height - 30, 20, rl.DARKGREEN)
        elif mode == i32<-DeferredMode.DEFERRED_NORMAL:
            rl.DrawTextureRec(gbuffer_texture(gbuffer.normal_texture_id, screen_width, screen_height), rl.Rectangle(x = 0.0, y = 0.0, width = f32<-screen_width, height = -f32<-screen_height), rm.Vector2.zero(), rl.RAYWHITE)
            rl.DrawText(normal_texture_text, 10, screen_height - 30, 20, rl.DARKGREEN)
        elif mode == i32<-DeferredMode.DEFERRED_ALBEDO:
            rl.DrawTextureRec(gbuffer_texture(gbuffer.albedo_spec_texture_id, screen_width, screen_height), rl.Rectangle(x = 0.0, y = 0.0, width = f32<-screen_width, height = -f32<-screen_height), rm.Vector2.zero(), rl.RAYWHITE)
            rl.DrawText(albedo_texture_text, 10, screen_height - 30, 20, rl.DARKGREEN)

        rl.DrawText(toggle_lights_text, 10, 40, 20, rl.DARKGRAY)
        rl.DrawText(switch_textures_text, 10, 70, 20, rl.DARKGRAY)
        rl.DrawFPS(10, 10)

    rlgl.rlUnloadFramebuffer(gbuffer.framebuffer_id)
    rlgl.rlUnloadTexture(gbuffer.position_texture_id)
    rlgl.rlUnloadTexture(gbuffer.normal_texture_id)
    rlgl.rlUnloadTexture(gbuffer.albedo_spec_texture_id)
    rlgl.rlUnloadTexture(gbuffer.depth_renderbuffer_id)
    return 0
