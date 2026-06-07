import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as rm

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
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
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - fog rendering")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 2.0, y = 2.0, z = 6.0),
        target = rl.Vector3(x = 0.0, y = 0.5, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    var model_a = rl.load_model_from_mesh(rl.gen_mesh_torus(0.4, 1.0, 16, 32))
    defer rl.unload_model(model_a)
    var model_b = rl.load_model_from_mesh(rl.gen_mesh_cube(1.0, 1.0, 1.0))
    defer rl.unload_model(model_b)
    var model_c = rl.load_model_from_mesh(rl.gen_mesh_sphere(0.5, 32, 32))
    defer rl.unload_model(model_c)

    let texture = rl.load_texture("texel_checker.png")
    defer rl.unload_texture(texture)
    rl.set_material_texture(model_a.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)
    rl.set_material_texture(model_b.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)
    rl.set_material_texture(model_c.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    var shader = rl.load_shader(
        rl.text_format("shaders/glsl%i/lighting.vs", GLSL_VERSION),
        rl.text_format("shaders/glsl%i/fog.fs", GLSL_VERSION)
    )
    defer rl.unload_shader(shader)
    unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_MATRIX_MODEL] = rl.get_shader_location(
        shader,
        "matModel"
    )
    unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW] = rl.get_shader_location(shader, "viewPos")

    let ambient_location = rl.get_shader_location(shader, "ambient")
    let ambient = array[float, 4](0.2, 0.2, 0.2, 1.0)
    rl.set_shader_value(shader, ambient_location, ambient, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)

    let fog_color_location = rl.get_shader_location(shader, "fogColor")
    let fog_color = rl.color_normalize(rl.GRAY)
    rl.set_shader_value(shader, fog_color_location, fog_color, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)

    var fog_density: float = 0.15
    let fog_density_location = rl.get_shader_location(shader, "fogDensity")
    rl.set_shader_value(shader, fog_density_location, fog_density, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

    unsafe: model_a.materials[0].shader = shader
    unsafe: model_b.materials[0].shader = shader
    unsafe: model_c.materials[0].shader = shader

    create_light(
        0,
        int<-LightType.LIGHT_POINT,
        rl.Vector3(x = 0.0, y = 2.0, z = 6.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.WHITE,
        shader
    )

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        if rl.is_key_down(rl.KeyboardKey.KEY_UP):
            fog_density += 0.001
            if fog_density > 1.0:
                fog_density = 1.0

        if rl.is_key_down(rl.KeyboardKey.KEY_DOWN):
            fog_density -= 0.001
            if fog_density < 0.0:
                fog_density = 0.0

        rl.set_shader_value(
            shader,
            fog_density_location,
            fog_density,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT
        )

        model_a.transform = rm.matrix_multiply(model_a.transform, rm.matrix_rotate_x(-0.025))
        model_a.transform = rm.matrix_multiply(model_a.transform, rm.matrix_rotate_z(0.012))

        let camera_position = array[float, 3](camera.position.x, camera.position.y, camera.position.z)
        rl.set_shader_value(
            shader,
            unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW],
            camera_position,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3
        )

        rl.begin_drawing()
        rl.clear_background(rl.GRAY)

        rl.begin_mode_3d(camera)
        rl.draw_model(model_a, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 1.0, rl.WHITE)
        rl.draw_model(model_b, rl.Vector3(x = -2.6, y = 0.0, z = 0.0), 1.0, rl.WHITE)
        rl.draw_model(model_c, rl.Vector3(x = 2.6, y = 0.0, z = 0.0), 1.0, rl.WHITE)

        var x = -20
        while x < 20:
            rl.draw_model(model_a, rl.Vector3(x = float<-x, y = 0.0, z = 2.0), 1.0, rl.WHITE)
            x += 2
        rl.end_mode_3d()

        rl.draw_text(
            rl.text_format("Use KEY_UP/KEY_DOWN to change fog density [%.2f]", fog_density),
            10,
            10,
            20,
            rl.RAYWHITE
        )
        rl.end_drawing()

    return 0
