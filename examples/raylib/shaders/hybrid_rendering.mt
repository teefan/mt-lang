import std.math as math
import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.rlgl as rlgl
import std.raymath as rm


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330
const DEPTH_TEXTURE_FORMAT: int = 19


struct RayLocations:
    cam_pos: int
    cam_dir: int
    screen_center: int


function load_render_texture_depth_tex(width: int, height: int) -> rl.RenderTexture2D:
    var target = zero[rl.RenderTexture2D]
    target.id = rlgl.load_framebuffer()

    if target.id > uint<-0:
        rlgl.enable_framebuffer(target.id)
        target.texture = rl.Texture(
            id = rlgl.load_texture(null, width, height, int<-rl.PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8, 1),
            width = width,
            height = height,
            format = int<-rl.PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
            mipmaps = 1,
        )
        target.depth = rl.Texture(
            id = rlgl.load_texture_depth(width, height, false),
            width = width,
            height = height,
            format = DEPTH_TEXTURE_FORMAT,
            mipmaps = 1,
        )

        rlgl.framebuffer_attach(target.id, target.texture.id, int<-rlgl.FramebufferAttachType.RL_ATTACHMENT_COLOR_CHANNEL0, int<-rlgl.FramebufferAttachTextureType.RL_ATTACHMENT_TEXTURE2D, 0)
        rlgl.framebuffer_attach(target.id, target.depth.id, int<-rlgl.FramebufferAttachType.RL_ATTACHMENT_DEPTH, int<-rlgl.FramebufferAttachTextureType.RL_ATTACHMENT_TEXTURE2D, 0)

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
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - hybrid rendering")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let raymarch_shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/hybrid_raymarch.fs", GLSL_VERSION))
    defer rl.unload_shader(raymarch_shader)
    let raster_shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/hybrid_raster.fs", GLSL_VERSION))
    defer rl.unload_shader(raster_shader)

    let ray_locations = RayLocations(
        cam_pos = rl.get_shader_location(raymarch_shader, "camPos"),
        cam_dir = rl.get_shader_location(raymarch_shader, "camDir"),
        screen_center = rl.get_shader_location(raymarch_shader, "screenCenter"),
    )
    let screen_center = array[float, 2](float<-SCREEN_WIDTH / 2.0, float<-SCREEN_HEIGHT / 2.0)
    rl.set_shader_value(raymarch_shader, ray_locations.screen_center, screen_center, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

    let target = load_render_texture_depth_tex(SCREEN_WIDTH, SCREEN_HEIGHT)
    defer unload_render_texture_depth_tex(target)

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 0.5, y = 1.0, z = 1.5),
        target = rl.Vector3(x = 0.0, y = 0.5, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )
    let cam_dist: float = float<-(1.0 / math.tan(double<-(camera.fovy * 0.5) * math.PI / 180.0))

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        let camera_position = array[float, 3](camera.position.x, camera.position.y, camera.position.z)
        let camera_direction_vector = rm.vector3_scale(rm.vector3_normalize(rm.vector3_subtract(camera.target, camera.position)), cam_dist)
        let camera_direction = array[float, 3](camera_direction_vector.x, camera_direction_vector.y, camera_direction_vector.z)

        rl.set_shader_value(raymarch_shader, ray_locations.cam_pos, camera_position, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)
        rl.set_shader_value(raymarch_shader, ray_locations.cam_dir, camera_direction, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)

        rl.begin_texture_mode(target)
        rl.clear_background(rl.WHITE)
        rlgl.enable_depth_test()
        rl.begin_shader_mode(raymarch_shader)
        rl.draw_rectangle_rec(rl.Rectangle(x = 0.0, y = 0.0, width = float<-SCREEN_WIDTH, height = float<-SCREEN_HEIGHT), rl.WHITE)
        rl.end_shader_mode()

        rl.begin_mode_3d(camera)
        rl.begin_shader_mode(raster_shader)
        rl.draw_cube_wires_v(rl.Vector3(x = 0.0, y = 0.5, z = 1.0), rl.Vector3(x = 1.0, y = 1.0, z = 1.0), rl.RED)
        rl.draw_cube_v(rl.Vector3(x = 0.0, y = 0.5, z = 1.0), rl.Vector3(x = 1.0, y = 1.0, z = 1.0), rl.PURPLE)
        rl.draw_cube_wires_v(rl.Vector3(x = 0.0, y = 0.5, z = -1.0), rl.Vector3(x = 1.0, y = 1.0, z = 1.0), rl.DARKGREEN)
        rl.draw_cube_v(rl.Vector3(x = 0.0, y = 0.5, z = -1.0), rl.Vector3(x = 1.0, y = 1.0, z = 1.0), rl.YELLOW)
        rl.draw_grid(10, 1.0)
        rl.end_shader_mode()
        rl.end_mode_3d()
        rl.end_texture_mode()

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.draw_texture_rec(target.texture, rl.Rectangle(x = 0.0, y = 0.0, width = float<-SCREEN_WIDTH, height = -(float<-SCREEN_HEIGHT)), rl.Vector2(x = 0.0, y = 0.0), rl.WHITE)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
