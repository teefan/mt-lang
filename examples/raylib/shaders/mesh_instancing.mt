import std.math as math
import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as rm

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_INSTANCES: int = 10000
const GLSL_VERSION: int = 330
const DEG_TO_RAD: float = float<-(math.PI / 180.0)

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
    let target_value = array[float, 3](light.target.x, light.target.y, light.target.z)
    let color_value = array[float, 4](
        float<-light.color.r / 255.0,
        float<-light.color.g / 255.0,
        float<-light.color.b / 255.0,
        float<-light.color.a / 255.0
    )
    rl.set_shader_value(shader, light.position_loc, position_value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)
    rl.set_shader_value(shader, light.target_loc, target_value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)
    rl.set_shader_value(shader, light.color_loc, color_value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - mesh instancing")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = -125.0, y = 125.0, z = -125.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    let cube = rl.gen_mesh_cube(1.0, 1.0, 1.0)
    defer rl.unload_mesh(cube)

    var transforms: array[rl.Matrix, MAX_INSTANCES] = zero[array[rl.Matrix, MAX_INSTANCES]]
    var instance_index = 0
    while instance_index < MAX_INSTANCES:
        let translation = rm.matrix_translate(
            float<-rl.get_random_value(-50, 50),
            float<-rl.get_random_value(-50, 50),
            float<-rl.get_random_value(-50, 50)
        )
        let axis = rm.vector3_normalize(
            rl.Vector3(
                x = float<-rl.get_random_value(0, 360),
                y = float<-rl.get_random_value(0, 360),
                z = float<-rl.get_random_value(0, 360)
            )
        )
        let angle = float<-rl.get_random_value(0, 180) * DEG_TO_RAD
        let rotation = rm.matrix_rotate(axis, angle)
        transforms[instance_index] = rm.matrix_multiply(rotation, translation)
        instance_index += 1

    var shader = rl.load_shader(
        rl.text_format("shaders/glsl%i/lighting_instancing.vs", GLSL_VERSION),
        rl.text_format("shaders/glsl%i/lighting.fs", GLSL_VERSION)
    )
    defer rl.unload_shader(shader)
    unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_MATRIX_MVP] = rl.get_shader_location(shader, "mvp")
    unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW] = rl.get_shader_location(shader, "viewPos")

    let ambient_location = rl.get_shader_location(shader, "ambient")
    let ambient = array[float, 4](0.2, 0.2, 0.2, 1.0)
    rl.set_shader_value(shader, ambient_location, ambient, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)
    create_light(
        0,
        int<-LightType.LIGHT_DIRECTIONAL,
        rl.Vector3(x = 50.0, y = 50.0, z = 0.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.WHITE,
        shader
    )

    var instanced_material = rl.load_material_default()
    unsafe: instanced_material.shader = shader
    unsafe: instanced_material.maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO].color = rl.RED

    var default_material = rl.load_material_default()
    unsafe: default_material.maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO].color = rl.BLUE

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)
        let camera_position = array[float, 3](camera.position.x, camera.position.y, camera.position.z)
        rl.set_shader_value(
            shader,
            unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW],
            camera_position,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3
        )

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_mesh(cube, default_material, rm.matrix_translate(-10.0, 0.0, 0.0))
        rl.draw_mesh_instanced(cube, instanced_material, ptr_of(transforms[0]), MAX_INSTANCES)
        rl.draw_mesh(cube, default_material, rm.matrix_translate(10.0, 0.0, 0.0))
        rl.end_mode_3d()

        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
