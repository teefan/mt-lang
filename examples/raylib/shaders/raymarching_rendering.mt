import std.raylib as rl
import std.raylib.runtime as rl_runtime

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_WINDOW_RESIZABLE)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - raymarching rendering")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 2.5, y = 2.5, z = 3.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.7),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 65.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    let shader = rl.load_shader(null, rl.text_format("shaders/glsl%i/raymarching.fs", GLSL_VERSION))
    defer rl.unload_shader(shader)

    let view_eye_location = rl.get_shader_location(shader, "viewEye")
    let view_center_location = rl.get_shader_location(shader, "viewCenter")
    let run_time_location = rl.get_shader_location(shader, "runTime")
    let resolution_location = rl.get_shader_location(shader, "resolution")

    var resolution = array[float, 2](float<-SCREEN_WIDTH, float<-SCREEN_HEIGHT)
    rl.set_shader_value(shader, resolution_location, resolution, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)

    var run_time: float = 0.0
    rl.disable_cursor()
    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_FIRST_PERSON)

        let camera_position = array[float, 3](camera.position.x, camera.position.y, camera.position.z)
        let camera_target = array[float, 3](camera.target.x, camera.target.y, camera.target.z)
        run_time += rl.get_frame_time()

        rl.set_shader_value(
            shader,
            view_eye_location,
            camera_position,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3
        )
        rl.set_shader_value(
            shader,
            view_center_location,
            camera_target,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3
        )
        rl.set_shader_value(shader, run_time_location, run_time, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

        if rl.is_window_resized():
            resolution[0] = float<-rl.get_screen_width()
            resolution[1] = float<-rl.get_screen_height()
            rl.set_shader_value(
                shader,
                resolution_location,
                resolution,
                int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2
            )

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.begin_shader_mode(shader)
        rl.draw_rectangle(0, 0, rl.get_screen_width(), rl.get_screen_height(), rl.WHITE)
        rl.end_shader_mode()
        rl.draw_text(
            "(c) Raymarching shader by Inigo Quilez. MIT License.",
            rl.get_screen_width() - 280,
            rl.get_screen_height() - 20,
            10,
            rl.BLACK
        )
        rl.end_drawing()

    return 0
