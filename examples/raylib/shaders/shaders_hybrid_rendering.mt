module examples.raylib.shaders.shaders_hybrid_rendering

import std.c.raylib as rl
import std.c.rlgl as rlgl
import std.raylib.math as rm

struct RayLocs:
    cam_pos: int
    cam_dir: int
    screen_center: int

const screen_width: int = 800
const screen_height: int = 450
const glsl_version: int = 330
const depth_texture_format: int = 19
const raymarch_shader_path_format: cstr = c"../resources/shaders/glsl%i/hybrid_raymarch.fs"
const raster_shader_path_format: cstr = c"../resources/shaders/glsl%i/hybrid_raster.fs"
const cam_pos_uniform_name: cstr = c"camPos"
const cam_dir_uniform_name: cstr = c"camDir"
const screen_center_uniform_name: cstr = c"screenCenter"
const window_title: cstr = c"raylib [shaders] example - hybrid rendering"


def load_render_texture_depth_tex(width: int, height: int) -> rl.RenderTexture2D:
    var target = zero[rl.RenderTexture2D]

    target.id = rlgl.rlLoadFramebuffer()
    if target.id > 0:
        rlgl.rlEnableFramebuffer(target.id)

        target.texture.id = rlgl.rlLoadTexture(null, width, height, int<-rl.PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8, 1)
        target.texture.width = width
        target.texture.height = height
        target.texture.format = int<-rl.PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8
        target.texture.mipmaps = 1

        target.depth.id = rlgl.rlLoadTextureDepth(width, height, false)
        target.depth.width = width
        target.depth.height = height
        target.depth.format = depth_texture_format
        target.depth.mipmaps = 1

        rlgl.rlFramebufferAttach(
            target.id,
            target.texture.id,
            int<-rlgl.rlFramebufferAttachType.RL_ATTACHMENT_COLOR_CHANNEL0,
            int<-rlgl.rlFramebufferAttachTextureType.RL_ATTACHMENT_TEXTURE2D,
            0,
        )
        rlgl.rlFramebufferAttach(
            target.id,
            target.depth.id,
            int<-rlgl.rlFramebufferAttachType.RL_ATTACHMENT_DEPTH,
            int<-rlgl.rlFramebufferAttachTextureType.RL_ATTACHMENT_TEXTURE2D,
            0,
        )

        rlgl.rlFramebufferComplete(target.id)
        rlgl.rlDisableFramebuffer()

    return target


def unload_render_texture_depth_tex(target: rl.RenderTexture2D) -> void:
    if target.id > 0:
        rlgl.rlUnloadTexture(target.texture.id)
        rlgl.rlUnloadTexture(target.depth.id)
        rlgl.rlUnloadFramebuffer(target.id)


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let raymarch_shader = rl.LoadShader(zero[cstr?], rl.TextFormat(raymarch_shader_path_format, glsl_version))
    defer rl.UnloadShader(raymarch_shader)
    let raster_shader = rl.LoadShader(zero[cstr?], rl.TextFormat(raster_shader_path_format, glsl_version))
    defer rl.UnloadShader(raster_shader)

    let march_locs = RayLocs(
        cam_pos = rl.GetShaderLocation(raymarch_shader, cam_pos_uniform_name),
        cam_dir = rl.GetShaderLocation(raymarch_shader, cam_dir_uniform_name),
        screen_center = rl.GetShaderLocation(raymarch_shader, screen_center_uniform_name),
    )

    var screen_center = array[float, 2](float<-screen_width / 2.0, float<-screen_height / 2.0)
    rl.SetShaderValue(raymarch_shader, march_locs.screen_center, ptr_of(screen_center[0]), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

    let target = load_render_texture_depth_tex(screen_width, screen_height)
    defer unload_render_texture_depth_tex(target)

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 0.5, y = 1.0, z = 1.5),
        target = rl.Vector3(x = 0.0, y = 0.5, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let cam_dist = float<-1.0 / rm.tan(camera.fovy * 0.5 * rm.deg2rad)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(camera), rl.CameraMode.CAMERA_ORBITAL)

        var camera_pos = array[float, 3](camera.position.x, camera.position.y, camera.position.z)
        rl.SetShaderValue(raymarch_shader, march_locs.cam_pos, ptr_of(camera_pos[0]), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)

        let cam_dir_value = camera.target.subtract(camera.position).normalize().scale(cam_dist)
        var cam_dir = array[float, 3](cam_dir_value.x, cam_dir_value.y, cam_dir_value.z)
        rl.SetShaderValue(raymarch_shader, march_locs.cam_dir, ptr_of(cam_dir[0]), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)

        rl.BeginTextureMode(target)
        rl.ClearBackground(rl.WHITE)

        rlgl.rlEnableDepthTest()
        rl.BeginShaderMode(raymarch_shader)
        rl.DrawRectangleRec(rl.Rectangle(x = 0.0, y = 0.0, width = float<-screen_width, height = float<-screen_height), rl.WHITE)
        rl.EndShaderMode()

        rl.BeginMode3D(camera)
        rl.BeginShaderMode(raster_shader)
        rl.DrawCubeWiresV(rl.Vector3(x = 0.0, y = 0.5, z = 1.0), rl.Vector3(x = 1.0, y = 1.0, z = 1.0), rl.RED)
        rl.DrawCubeV(rl.Vector3(x = 0.0, y = 0.5, z = 1.0), rl.Vector3(x = 1.0, y = 1.0, z = 1.0), rl.PURPLE)
        rl.DrawCubeWiresV(rl.Vector3(x = 0.0, y = 0.5, z = -1.0), rl.Vector3(x = 1.0, y = 1.0, z = 1.0), rl.DARKGREEN)
        rl.DrawCubeV(rl.Vector3(x = 0.0, y = 0.5, z = -1.0), rl.Vector3(x = 1.0, y = 1.0, z = 1.0), rl.YELLOW)
        rl.DrawGrid(10, 1.0)
        rl.EndShaderMode()
        rl.EndMode3D()
        rl.EndTextureMode()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.DrawTextureRec(
            target.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = float<-screen_width, height = -float<-screen_height),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE,
        )
        rl.DrawFPS(10, 10)

    return 0
