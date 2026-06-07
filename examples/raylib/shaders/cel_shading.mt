import std.c.rlgl as c_rlgl
import std.math as math
import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.rlgl as rlgl
import std.raymath as rm

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_LIGHTS: int = 4
const GLSL_VERSION: int = 330

enum LightType: int
    LIGHT_DIRECTIONAL = 0
    LIGHT_POINT = 1

struct Light:
    kind: int
    enabled: bool
    position: rl.Vector3
    target: rl.Vector3
    color: rl.Color
    enabled_loc: int
    type_loc: int
    position_loc: int
    target_loc: int
    color_loc: int


function create_light(
    slot: int,
    light_type: int,
    position: rl.Vector3,
    target: rl.Vector3,
    color: rl.Color,
    shader: rl.Shader
) -> Light:
    let light = Light(
        kind = light_type,
        enabled = true,
        position = position,
        target = target,
        color = color,
        enabled_loc = rl.get_shader_location(shader, rl.text_format("lights[%i].enabled", slot)),
        type_loc = rl.get_shader_location(shader, rl.text_format("lights[%i].type", slot)),
        position_loc = rl.get_shader_location(shader, rl.text_format("lights[%i].position", slot)),
        target_loc = rl.get_shader_location(shader, rl.text_format("lights[%i].target", slot)),
        color_loc = rl.get_shader_location(shader, rl.text_format("lights[%i].color", slot))
    )
    update_light_values(shader, light)
    return light


function update_light_values(shader: rl.Shader, light: Light) -> void:
    let enabled_value = if light.enabled: 1 else: 0
    rl.set_shader_value(shader, light.enabled_loc, enabled_value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT)
    rl.set_shader_value(shader, light.type_loc, light.kind, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT)

    let position_value = array[float, 3](light.position.x, light.position.y, light.position.z)
    rl.set_shader_value(shader, light.position_loc, position_value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)

    let target_value = array[float, 3](light.target.x, light.target.y, light.target.z)
    rl.set_shader_value(shader, light.target_loc, target_value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)

    let color_value = array[float, 4](
        float<-light.color.r / 255.0,
        float<-light.color.g / 255.0,
        float<-light.color.b / 255.0,
        float<-light.color.a / 255.0
    )
    rl.set_shader_value(shader, light.color_loc, color_value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - cel shading")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 9.0, y = 6.0, z = 9.0),
        target = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    var model = rl.load_model("models/old_car_new.glb")
    defer rl.unload_model(model)

    let cel_shader = rl.load_shader(
        rl.text_format("shaders/glsl%i/cel.vs", GLSL_VERSION),
        rl.text_format("shaders/glsl%i/cel.fs", GLSL_VERSION)
    )
    defer rl.unload_shader(cel_shader)
    let view_pos_location = rl.get_shader_location(cel_shader, "viewPos")

    let default_shader = unsafe: model.materials[0].shader
    unsafe: model.materials[0].shader = cel_shader

    var num_bands: float = 10.0
    let num_bands_location = rl.get_shader_location(cel_shader, "numBands")
    rl.set_shader_value(cel_shader, num_bands_location, num_bands, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

    let outline_shader = rl.load_shader(
        rl.text_format("shaders/glsl%i/outline_hull.vs", GLSL_VERSION),
        rl.text_format("shaders/glsl%i/outline_hull.fs", GLSL_VERSION)
    )
    defer rl.unload_shader(outline_shader)
    let outline_thickness_location = rl.get_shader_location(outline_shader, "outlineThickness")

    var lights: array[Light, MAX_LIGHTS] = zero[array[Light, MAX_LIGHTS]]
    lights[0] = create_light(
        0,
        int<-LightType.LIGHT_DIRECTIONAL,
        rl.Vector3(x = 50.0, y = 50.0, z = 50.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.WHITE,
        cel_shader
    )

    var cel_enabled = true
    var outline_enabled = true

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        let camera_position = array[float, 3](camera.position.x, camera.position.y, camera.position.z)
        rl.set_shader_value(
            cel_shader,
            view_pos_location,
            camera_position,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3
        )

        if rl.is_key_pressed(rl.KeyboardKey.KEY_Z):
            cel_enabled = not cel_enabled
            unsafe: model.materials[0].shader = if cel_enabled: cel_shader else: default_shader

        if rl.is_key_pressed(rl.KeyboardKey.KEY_C):
            outline_enabled = not outline_enabled

        if rl.is_key_pressed(rl.KeyboardKey.KEY_E) or rl.is_key_pressed_repeat(rl.KeyboardKey.KEY_E):
            num_bands = rm.clamp(num_bands + 1.0, 2.0, 20.0)
        if rl.is_key_pressed(rl.KeyboardKey.KEY_Q) or rl.is_key_pressed_repeat(rl.KeyboardKey.KEY_Q):
            num_bands = rm.clamp(num_bands - 1.0, 2.0, 20.0)
        rl.set_shader_value(
            cel_shader,
            num_bands_location,
            num_bands,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT
        )

        var light = lights[0]
        let time_seconds = rl.get_time()
        light.position = rl.Vector3(
            x = float<-(math.sin(-time_seconds * 0.3) * 5.0),
            y = 5.0,
            z = float<-(math.cos(-time_seconds * 0.3) * 5.0)
        )
        lights[0] = light
        update_light_values(cel_shader, lights[0])

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        if outline_enabled:
            let thickness: float = 0.005
            rl.set_shader_value(
                outline_shader,
                outline_thickness_location,
                thickness,
                int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT
            )
            rlgl.set_cull_face(int<-c_rlgl.rlCullMode.RL_CULL_FACE_FRONT)
            unsafe: model.materials[0].shader = outline_shader
            rl.draw_model(model, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 0.75, rl.WHITE)
            unsafe: model.materials[0].shader = if cel_enabled: cel_shader else: default_shader
            rlgl.set_cull_face(int<-c_rlgl.rlCullMode.RL_CULL_FACE_BACK)

        rl.draw_model(model, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 0.75, rl.WHITE)
        rl.draw_sphere_ex(lights[0].position, 0.2, 50, 50, rl.YELLOW)
        rl.draw_grid(10, 10.0)
        rl.end_mode_3d()

        let cel_text = if cel_enabled: "ON" else: "OFF"
        let outline_text = if outline_enabled: "ON" else: "OFF"
        rl.draw_fps(10, 10)
        rl.draw_text(
            rl.text_format("Cel: %s  [Z]", cel_text),
            10,
            65,
            20,
            if cel_enabled: rl.DARKGREEN else: rl.DARKGRAY
        )
        rl.draw_text(
            rl.text_format("Outline: %s  [C]", outline_text),
            10,
            90,
            20,
            if outline_enabled: rl.DARKGREEN else: rl.DARKGRAY
        )
        rl.draw_text(rl.text_format("Bands: %.0f  [Q/E]", num_bands), 10, 115, 20, rl.DARKGRAY)
        rl.end_drawing()

    return 0
