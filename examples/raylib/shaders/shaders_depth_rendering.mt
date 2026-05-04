module examples.raylib.shaders.shaders_depth_rendering

import std.c.raylib as rl
import std.c.rlgl as rlgl

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const depth_texture_format: i32 = 19
const shader_path_format: cstr = c"../resources/shaders/glsl%i/depth_render.fs"
const depth_uniform_name: cstr = c"depthTexture"
const flip_uniform_name: cstr = c"flipY"
const window_title: cstr = c"raylib [shaders] example - depth rendering"


def load_render_texture_depth_tex(width: i32, height: i32) -> rl.RenderTexture2D:
    var target = zero[rl.RenderTexture2D]()

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
        position = rl.Vector3(x = 4.0, y = 1.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let target = load_render_texture_depth_tex(screen_width, screen_height)
    defer unload_render_texture_depth_tex(target)

    let depth_shader = rl.LoadShader(zero[cstr?](), rl.TextFormat(shader_path_format, glsl_version))
    defer rl.UnloadShader(depth_shader)
    let depth_loc = rl.GetShaderLocation(depth_shader, depth_uniform_name)
    let flip_texture_loc = rl.GetShaderLocation(depth_shader, flip_uniform_name)
    var flip_y = 1
    rl.SetShaderValue(depth_shader, flip_texture_loc, ptr_of(flip_y), rl.ShaderUniformDataType.SHADER_UNIFORM_INT)

    let cube = rl.LoadModelFromMesh(rl.GenMeshCube(1.0, 1.0, 1.0))
    defer rl.UnloadModel(cube)
    let floor = rl.LoadModelFromMesh(rl.GenMeshPlane(20.0, 20.0, 1, 1))
    defer rl.UnloadModel(floor)

    rl.DisableCursor()
    defer rl.EnableCursor()

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(camera), rl.CameraMode.CAMERA_FREE)

        rl.BeginTextureMode(target)
        rl.ClearBackground(rl.WHITE)
        rl.BeginMode3D(camera)
        rl.DrawModel(cube, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 3.0, rl.YELLOW)
        rl.DrawModel(floor, rl.Vector3(x = 10.0, y = 0.0, z = 2.0), 2.0, rl.RED)
        rl.EndMode3D()
        rl.EndTextureMode()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginShaderMode(depth_shader)
        rl.SetShaderValueTexture(depth_shader, depth_loc, target.depth)
        rl.DrawTexture(target.depth, 0, 0, rl.WHITE)
        rl.EndShaderMode()

        rl.DrawRectangle(10, 10, 320, 93, rl.Fade(rl.SKYBLUE, 0.5))
        rl.DrawRectangleLines(10, 10, 320, 93, rl.BLUE)
        rl.DrawText(c"Camera Controls:", 20, 20, 10, rl.BLACK)
        rl.DrawText(c"- WASD to move", 40, 40, 10, rl.DARKGRAY)
        rl.DrawText(c"- Mouse Wheel Pressed to Pan", 40, 60, 10, rl.DARKGRAY)
        rl.DrawText(c"- Z to zoom to (0, 0, 0)", 40, 80, 10, rl.DARKGRAY)

        rl.EndDrawing()

    return 0
