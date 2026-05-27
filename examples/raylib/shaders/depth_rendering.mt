import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.rlgl as rlgl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function load_render_texture_depth_tex(width: int, height: int) -> rl.RenderTexture2D:
    var target = zero[rl.RenderTexture2D]
    target.id = rlgl.load_framebuffer()

    if target.id > uint<-0:
        rlgl.enable_framebuffer(target.id)

        target.texture = rl.Texture(
            id = rlgl.load_texture(null, width, height, int<-rl.PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8, 1),
            width = width,
            height = height,
            mipmaps = 1,
            format = int<-rl.PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
        )
        target.depth = rl.Texture(
            id = rlgl.load_texture_depth(width, height, false),
            width = width,
            height = height,
            mipmaps = 1,
            format = 19,
        )

        rlgl.framebuffer_attach(
            target.id,
            target.texture.id,
            int<-rlgl.FramebufferAttachType.RL_ATTACHMENT_COLOR_CHANNEL0,
            int<-rlgl.FramebufferAttachTextureType.RL_ATTACHMENT_TEXTURE2D,
            0,
        )
        rlgl.framebuffer_attach(
            target.id,
            target.depth.id,
            int<-rlgl.FramebufferAttachType.RL_ATTACHMENT_DEPTH,
            int<-rlgl.FramebufferAttachTextureType.RL_ATTACHMENT_TEXTURE2D,
            0,
        )

        if rlgl.framebuffer_complete(target.id):
            rl.trace_log(int<-rl.TraceLogLevel.LOG_INFO, "FBO: [ID %i] Framebuffer object created successfully", target.id)

        rlgl.disable_framebuffer()

    return target


function unload_render_texture_depth_tex(target: rl.RenderTexture2D) -> void:
    if target.id > uint<-0:
        rlgl.unload_texture(target.texture.id)
        rlgl.unload_texture(target.depth.id)
        rlgl.unload_framebuffer(target.id)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - depth rendering")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 4.0, y = 1.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let target = load_render_texture_depth_tex(SCREEN_WIDTH, SCREEN_HEIGHT)
    defer unload_render_texture_depth_tex(target)

    let depth_shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/depth_render.fs", GLSL_VERSION))
    defer rl.unload_shader(depth_shader)
    let depth_location = rl.get_shader_location(depth_shader, "depthTexture")
    let flip_texture_location = rl.get_shader_location(depth_shader, "flipY")
    rl.set_shader_value(depth_shader, flip_texture_location, 1, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT)

    let cube = rl.load_model_from_mesh(rl.gen_mesh_cube(1.0, 1.0, 1.0))
    defer rl.unload_model(cube)
    let floor = rl.load_model_from_mesh(rl.gen_mesh_plane(20.0, 20.0, 1, 1))
    defer rl.unload_model(floor)

    rl.disable_cursor()
    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_FREE)

        rl.begin_texture_mode(target)
        rl.clear_background(rl.WHITE)
        rl.begin_mode_3d(camera)
        rl.draw_model(cube, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 3.0, rl.YELLOW)
        rl.draw_model(floor, rl.Vector3(x = 10.0, y = 0.0, z = 2.0), 2.0, rl.RED)
        rl.end_mode_3d()
        rl.end_texture_mode()

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.begin_shader_mode(depth_shader)
        rl.set_shader_value_texture(depth_shader, depth_location, target.depth)
        rl.draw_texture(target.depth, 0, 0, rl.WHITE)
        rl.end_shader_mode()

        rl.draw_rectangle(10, 10, 320, 93, rl.fade(rl.SKYBLUE, 0.5))
        rl.draw_rectangle_lines(10, 10, 320, 93, rl.BLUE)
        rl.draw_text("Camera Controls:", 20, 20, 10, rl.BLACK)
        rl.draw_text("- WASD to move", 40, 40, 10, rl.DARKGRAY)
        rl.draw_text("- Mouse Wheel Pressed to Pan", 40, 60, 10, rl.DARKGRAY)
        rl.draw_text("- Z to zoom to (0, 0, 0)", 40, 80, 10, rl.DARKGRAY)
        rl.end_drawing()

    return 0
