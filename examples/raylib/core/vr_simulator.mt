import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - vr simulator")

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal(c"vr_simulator missing resources directory")

    let device = rl.VrDeviceInfo(
        hResolution = 2160,
        vResolution = 1200,
        hScreenSize = 0.133793,
        vScreenSize = 0.0669,
        eyeToScreenDistance = 0.041,
        lensSeparationDistance = 0.07,
        interpupillaryDistance = 0.07,
        lensDistortionValues = array[float, 4](1.0, 0.22, 0.24, 0.0),
        chromaAbCorrection = array[float, 4](0.996, -0.004, 1.014, 0.0),
    )

    let config = rl.load_vr_stereo_config(device)
    let distortion = rl.load_shader(null, rl.text_format("shaders/glsl%i/distortion.fs", GLSL_VERSION))

    rl.set_shader_value(distortion, rl.get_shader_location(distortion, "leftLensCenter"), config.leftLensCenter, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
    rl.set_shader_value(distortion, rl.get_shader_location(distortion, "rightLensCenter"), config.rightLensCenter, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
    rl.set_shader_value(distortion, rl.get_shader_location(distortion, "leftScreenCenter"), config.leftScreenCenter, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
    rl.set_shader_value(distortion, rl.get_shader_location(distortion, "rightScreenCenter"), config.rightScreenCenter, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
    rl.set_shader_value(distortion, rl.get_shader_location(distortion, "scale"), config.scale, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
    rl.set_shader_value(distortion, rl.get_shader_location(distortion, "scaleIn"), config.scaleIn, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
    rl.set_shader_value(distortion, rl.get_shader_location(distortion, "deviceWarpParam"), device.lensDistortionValues, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)
    rl.set_shader_value(distortion, rl.get_shader_location(distortion, "chromaAbParam"), device.chromaAbCorrection, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)

    let target = rl.load_render_texture(device.hResolution, device.vResolution)
    let source_rec = rl.Rectangle(x = 0.0, y = 0.0, width = float<-target.texture.width, height = -float<-target.texture.height)
    let dest_rec = rl.Rectangle(x = 0.0, y = 0.0, width = float<-rl.get_screen_width(), height = float<-rl.get_screen_height())

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 5.0, y = 2.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 2.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 60.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )
    let cube_position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    rl.disable_cursor()
    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_FIRST_PERSON)

        rl.begin_texture_mode(target)
        rl.clear_background(rl.RAYWHITE)
        rl.begin_vr_stereo_mode(config)
        rl.begin_mode_3d(camera)
        rl.draw_cube(cube_position, 2.0, 2.0, 2.0, rl.RED)
        rl.draw_cube_wires(cube_position, 2.0, 2.0, 2.0, rl.MAROON)
        rl.draw_grid(40, 1.0)
        rl.end_mode_3d()
        rl.end_vr_stereo_mode()
        rl.end_texture_mode()

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.begin_shader_mode(distortion)
        rl.draw_texture_pro(target.texture, source_rec, dest_rec, rl.Vector2(x = 0.0, y = 0.0), 0.0, rl.WHITE)
        rl.end_shader_mode()
        rl.draw_fps(10, 10)
        rl.end_drawing()

    rl.unload_vr_stereo_config(config)
    rl.unload_render_texture(target)
    rl.unload_shader(distortion)
    rl.close_window()
    return 0
