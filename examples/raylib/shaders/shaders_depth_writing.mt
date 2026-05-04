module examples.raylib.shaders.shaders_depth_writing

import std.c.raylib as rl
import std.c.rlgl as rlgl

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const depth_texture_format: i32 = 19
const shader_path_format: cstr = c"../resources/shaders/glsl%i/depth_write.fs"
const window_title: cstr = c"raylib [shaders] example - depth writing"


def load_render_texture_depth_tex(width: i32, height: i32) -> rl.RenderTexture2D:
    var target = zero[rl.RenderTexture2D]

    target.id = rlgl.rlLoadFramebuffer()
    if target.id > 0:
        rlgl.rlEnableFramebuffer(target.id)

        target.texture.id = rlgl.rlLoadTexture(null, width, height, i32<-rl.PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8, 1)
        target.texture.width = width
        target.texture.height = height
        target.texture.format = i32<-rl.PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8
        target.texture.mipmaps = 1

        target.depth.id = rlgl.rlLoadTextureDepth(width, height, false)
        target.depth.width = width
        target.depth.height = height
        target.depth.format = depth_texture_format
        target.depth.mipmaps = 1

        rlgl.rlFramebufferAttach(
            target.id,
            target.texture.id,
            i32<-rlgl.rlFramebufferAttachType.RL_ATTACHMENT_COLOR_CHANNEL0,
            i32<-rlgl.rlFramebufferAttachTextureType.RL_ATTACHMENT_TEXTURE2D,
            0,
        )
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


def unload_render_texture_depth_tex(target: rl.RenderTexture2D) -> void:
    if target.id > 0:
        rlgl.rlUnloadTexture(target.texture.id)
        rlgl.rlUnloadTexture(target.depth.id)
        rlgl.rlUnloadFramebuffer(target.id)


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 2.0, y = 2.0, z = 3.0),
        target = rl.Vector3(x = 0.0, y = 0.5, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let target = load_render_texture_depth_tex(screen_width, screen_height)
    defer unload_render_texture_depth_tex(target)

    let shader = rl.LoadShader(zero[cstr?], rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(shader)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(camera), rl.CameraMode.CAMERA_ORBITAL)

        rl.BeginTextureMode(target)
        rl.ClearBackground(rl.WHITE)
        rl.BeginMode3D(camera)
        rl.BeginShaderMode(shader)
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
            rl.Rectangle(x = 0.0, y = 0.0, width = f32<-screen_width, height = -f32<-screen_height),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE,
        )
        rl.DrawFPS(10, 10)

    return 0
