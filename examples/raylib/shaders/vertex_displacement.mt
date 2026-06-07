import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.rlgl as rlgl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - vertex displacement")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 20.0, y = 5.0, z = -20.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 60.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    let shader = rl.load_shader(
        rl.text_format("shaders/glsl%i/vertex_displacement.vs", GLSL_VERSION),
        rl.text_format("shaders/glsl%i/vertex_displacement.fs", GLSL_VERSION)
    )
    defer rl.unload_shader(shader)

    let perlin_noise_image = rl.gen_image_perlin_noise(512, 512, 0, 0, 1.0)
    let perlin_noise_map = rl.load_texture_from_image(perlin_noise_image)
    defer rl.unload_texture(perlin_noise_map)
    rl.unload_image(perlin_noise_image)

    let perlin_noise_map_location = rl.get_shader_location(shader, "perlinNoiseMap")
    rlgl.enable_shader(shader.id)
    rlgl.active_texture_slot(1)
    rlgl.enable_texture(perlin_noise_map.id)
    rlgl.set_uniform_sampler(perlin_noise_map_location, uint<-1)

    let plane_mesh = rl.gen_mesh_plane(50.0, 50.0, 50, 50)
    var plane_model = rl.load_model_from_mesh(plane_mesh)
    defer rl.unload_model(plane_model)
    unsafe: plane_model.materials[0].shader = shader

    let time_location = rl.get_shader_location(shader, "time")
    var time: float = 0.0

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_FREE)
        time += rl.get_frame_time()
        rl.set_shader_value(shader, time_location, time, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.begin_mode_3d(camera)
        rl.begin_shader_mode(shader)
        rl.draw_model(plane_model, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 1.0, rl.WHITE)
        rl.end_shader_mode()
        rl.end_mode_3d()
        rl.draw_text("Vertex displacement", 10, 10, 20, rl.DARKGRAY)
        rl.draw_fps(10, 40)
        rl.end_drawing()

    return 0
