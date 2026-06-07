import std.raylib as rl
import std.raylib.runtime as rl_runtime

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
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - basic lighting")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 2.0, y = 4.0, z = 6.0),
        target = rl.Vector3(x = 0.0, y = 0.5, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    let shader = rl.load_shader(
        rl.text_format("shaders/glsl%i/lighting.vs", GLSL_VERSION),
        rl.text_format("shaders/glsl%i/lighting.fs", GLSL_VERSION)
    )
    defer rl.unload_shader(shader)

    let view_pos_location = rl.get_shader_location(shader, "viewPos")
    let ambient_location = rl.get_shader_location(shader, "ambient")
    let ambient = array[float, 4](0.1, 0.1, 0.1, 1.0)
    rl.set_shader_value(shader, ambient_location, ambient, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)

    var lights: array[Light, MAX_LIGHTS] = zero[array[Light, MAX_LIGHTS]]
    lights[0] = create_light(
        0,
        int<-LightType.LIGHT_POINT,
        rl.Vector3(x = -2.0, y = 1.0, z = -2.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.YELLOW,
        shader
    )
    lights[1] = create_light(
        1,
        int<-LightType.LIGHT_POINT,
        rl.Vector3(x = 2.0, y = 1.0, z = 2.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.RED,
        shader
    )
    lights[2] = create_light(
        2,
        int<-LightType.LIGHT_POINT,
        rl.Vector3(x = -2.0, y = 1.0, z = 2.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.GREEN,
        shader
    )
    lights[3] = create_light(
        3,
        int<-LightType.LIGHT_POINT,
        rl.Vector3(x = 2.0, y = 1.0, z = -2.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.BLUE,
        shader
    )

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        let camera_position = array[float, 3](camera.position.x, camera.position.y, camera.position.z)
        rl.set_shader_value(
            shader,
            view_pos_location,
            camera_position,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3
        )

        if rl.is_key_pressed(rl.KeyboardKey.KEY_Y):
            var light = lights[0]
            light.enabled = not light.enabled
            lights[0] = light
        if rl.is_key_pressed(rl.KeyboardKey.KEY_R):
            var light = lights[1]
            light.enabled = not light.enabled
            lights[1] = light
        if rl.is_key_pressed(rl.KeyboardKey.KEY_G):
            var light = lights[2]
            light.enabled = not light.enabled
            lights[2] = light
        if rl.is_key_pressed(rl.KeyboardKey.KEY_B):
            var light = lights[3]
            light.enabled = not light.enabled
            lights[3] = light

        var light_index = 0
        while light_index < MAX_LIGHTS:
            update_light_values(shader, lights[light_index])
            light_index += 1

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.begin_shader_mode(shader)
        rl.draw_plane(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector2(x = 10.0, y = 10.0), rl.WHITE)
        rl.draw_cube(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 2.0, 4.0, 2.0, rl.WHITE)
        rl.end_shader_mode()

        light_index = 0
        while light_index < MAX_LIGHTS:
            let light = lights[light_index]
            if light.enabled:
                rl.draw_sphere_ex(light.position, 0.2, 8, 8, light.color)
            else:
                rl.draw_sphere_wires(light.position, 0.2, 8, 8, rl.color_alpha(light.color, 0.3))
            light_index += 1

        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        rl.draw_fps(10, 10)
        rl.draw_text("Use keys [Y][R][G][B] to toggle lights", 10, 40, 20, rl.DARKGRAY)
        rl.end_drawing()

    return 0
