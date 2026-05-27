import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_LIGHTS: int = 4
const GLSL_VERSION: int = 330


enum LightType: int
    LIGHT_DIRECTIONAL = 0
    LIGHT_POINT = 1
    LIGHT_SPOT = 2


struct Light:
    kind: int
    enabled: bool
    position: rl.Vector3
    target: rl.Vector3
    color: array[float, 4]
    intensity: float
    type_loc: int
    enabled_loc: int
    position_loc: int
    target_loc: int
    color_loc: int
    intensity_loc: int


function color_vector(color: rl.Color) -> array[float, 4]:
    return array[float, 4](
        float<-color.r / 255.0,
        float<-color.g / 255.0,
        float<-color.b / 255.0,
        float<-color.a / 255.0,
    )


function light_display_color(light: Light) -> rl.Color:
    return rl.Color(
        r = ubyte<-(light.color[0] * 255.0),
        g = ubyte<-(light.color[1] * 255.0),
        b = ubyte<-(light.color[2] * 255.0),
        a = ubyte<-(light.color[3] * 255.0),
    )


function create_light(slot: int, light_type: int, position: rl.Vector3, target: rl.Vector3, color: rl.Color, intensity: float, shader: rl.Shader) -> Light:
    let light = Light(
        kind = light_type,
        enabled = true,
        position = position,
        target = target,
        color = color_vector(color),
        intensity = intensity,
        type_loc = rl.get_shader_location(shader, rl.text_format("lights[%i].type", slot)),
        enabled_loc = rl.get_shader_location(shader, rl.text_format("lights[%i].enabled", slot)),
        position_loc = rl.get_shader_location(shader, rl.text_format("lights[%i].position", slot)),
        target_loc = rl.get_shader_location(shader, rl.text_format("lights[%i].target", slot)),
        color_loc = rl.get_shader_location(shader, rl.text_format("lights[%i].color", slot)),
        intensity_loc = rl.get_shader_location(shader, rl.text_format("lights[%i].intensity", slot)),
    )
    update_light(shader, light)
    return light


function update_light(shader: rl.Shader, light: Light) -> void:
    let enabled_value = if light.enabled: 1 else: 0
    let position_value = array[float, 3](light.position.x, light.position.y, light.position.z)
    let target_value = array[float, 3](light.target.x, light.target.y, light.target.z)
    rl.set_shader_value(shader, light.enabled_loc, enabled_value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT)
    rl.set_shader_value(shader, light.type_loc, light.kind, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT)
    rl.set_shader_value(shader, light.position_loc, position_value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)
    rl.set_shader_value(shader, light.target_loc, target_value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)
    rl.set_shader_value(shader, light.color_loc, light.color, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)
    rl.set_shader_value(shader, light.intensity_loc, light.intensity, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - basic pbr")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 2.0, y = 2.0, z = 6.0),
        target = rl.Vector3(x = 0.0, y = 0.5, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var shader = rl.load_shader(
        rl.text_format("shaders/glsl%i/pbr.vs", GLSL_VERSION),
        rl.text_format("shaders/glsl%i/pbr.fs", GLSL_VERSION),
    )
    defer rl.unload_shader(shader)
    unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_MAP_ALBEDO] = rl.get_shader_location(shader, "albedoMap")
    unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_MAP_METALNESS] = rl.get_shader_location(shader, "mraMap")
    unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_MAP_NORMAL] = rl.get_shader_location(shader, "normalMap")
    unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_MAP_EMISSION] = rl.get_shader_location(shader, "emissiveMap")
    unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_COLOR_DIFFUSE] = rl.get_shader_location(shader, "albedoColor")
    unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW] = rl.get_shader_location(shader, "viewPos")

    let light_count_location = rl.get_shader_location(shader, "numOfLights")
    rl.set_shader_value(shader, light_count_location, MAX_LIGHTS, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT)
    let ambient_color_location = rl.get_shader_location(shader, "ambientColor")
    let ambient_intensity_location = rl.get_shader_location(shader, "ambient")
    let ambient_color = array[float, 3](26.0 / 255.0, 32.0 / 255.0, 135.0 / 255.0)
    let ambient_intensity: float = 0.02
    rl.set_shader_value(shader, ambient_color_location, ambient_color, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)
    rl.set_shader_value(shader, ambient_intensity_location, ambient_intensity, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

    let metallic_value_location = rl.get_shader_location(shader, "metallicValue")
    let roughness_value_location = rl.get_shader_location(shader, "roughnessValue")
    let emissive_intensity_location = rl.get_shader_location(shader, "emissivePower")
    let emissive_color_location = rl.get_shader_location(shader, "emissiveColor")
    let texture_tiling_location = rl.get_shader_location(shader, "tiling")

    var car = rl.load_model("models/old_car_new.glb")
    defer rl.unload_model(car)
    unsafe: car.materials[0].shader = shader
    unsafe:
        car.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO].color = rl.WHITE
        car.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_METALNESS].value = 1.0
        car.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_ROUGHNESS].value = 0.0
        car.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_OCCLUSION].value = 1.0
        car.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_EMISSION].color = rl.Color(r = 255, g = 162, b = 0, a = 255)

    let car_albedo = rl.load_texture("old_car_d.png")
    let car_mra = rl.load_texture("old_car_mra.png")
    let car_normal = rl.load_texture("old_car_n.png")
    let car_emission = rl.load_texture("old_car_e.png")
    rl.set_material_texture(car.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, car_albedo)
    rl.set_material_texture(car.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_METALNESS, car_mra)
    rl.set_material_texture(car.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_NORMAL, car_normal)
    rl.set_material_texture(car.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_EMISSION, car_emission)

    var floor = rl.load_model("models/plane.glb")
    defer rl.unload_model(floor)
    unsafe: floor.materials[0].shader = shader
    unsafe:
        floor.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO].color = rl.WHITE
        floor.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_METALNESS].value = 0.8
        floor.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_ROUGHNESS].value = 0.1
        floor.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_OCCLUSION].value = 1.0
        floor.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_EMISSION].color = rl.BLACK

    let floor_albedo = rl.load_texture("road_a.png")
    let floor_mra = rl.load_texture("road_mra.png")
    let floor_normal = rl.load_texture("road_n.png")
    rl.set_material_texture(floor.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, floor_albedo)
    rl.set_material_texture(floor.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_METALNESS, floor_mra)
    rl.set_material_texture(floor.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_NORMAL, floor_normal)

    let car_texture_tiling = array[float, 2](0.5, 0.5)
    let floor_texture_tiling = array[float, 2](0.5, 0.5)

    var lights: array[Light, MAX_LIGHTS] = zero[array[Light, MAX_LIGHTS]]
    lights[0] = create_light(0, int<-LightType.LIGHT_POINT, rl.Vector3(x = -1.0, y = 1.0, z = -2.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.YELLOW, 4.0, shader)
    lights[1] = create_light(1, int<-LightType.LIGHT_POINT, rl.Vector3(x = 2.0, y = 1.0, z = 1.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.GREEN, 3.3, shader)
    lights[2] = create_light(2, int<-LightType.LIGHT_POINT, rl.Vector3(x = -2.0, y = 1.0, z = 1.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.RED, 8.3, shader)
    lights[3] = create_light(3, int<-LightType.LIGHT_POINT, rl.Vector3(x = 1.0, y = 1.0, z = -2.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.BLUE, 2.0, shader)

    let use_texture_location_albedo = rl.get_shader_location(shader, "useTexAlbedo")
    let use_texture_location_normal = rl.get_shader_location(shader, "useTexNormal")
    let use_texture_location_mra = rl.get_shader_location(shader, "useTexMRA")
    let use_texture_location_emissive = rl.get_shader_location(shader, "useTexEmissive")
    rl.set_shader_value(shader, use_texture_location_albedo, 1, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT)
    rl.set_shader_value(shader, use_texture_location_normal, 1, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT)
    rl.set_shader_value(shader, use_texture_location_mra, 1, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT)
    rl.set_shader_value(shader, use_texture_location_emissive, 1, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)
        let camera_position = array[float, 3](camera.position.x, camera.position.y, camera.position.z)
        rl.set_shader_value(
            shader,
            unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW],
            camera_position,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3,
        )

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            var light = lights[2]
            light.enabled = not light.enabled
            lights[2] = light
        if rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            var light = lights[1]
            light.enabled = not light.enabled
            lights[1] = light
        if rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            var light = lights[3]
            light.enabled = not light.enabled
            lights[3] = light
        if rl.is_key_pressed(rl.KeyboardKey.KEY_FOUR):
            var light = lights[0]
            light.enabled = not light.enabled
            lights[0] = light

        var light_index = 0
        while light_index < MAX_LIGHTS:
            update_light(shader, lights[light_index])
            light_index += 1

        rl.begin_drawing()
        rl.clear_background(rl.BLACK)
        rl.begin_mode_3d(camera)

        let floor_emissive = color_vector(unsafe: floor.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_EMISSION].color)
        rl.set_shader_value(shader, texture_tiling_location, floor_texture_tiling, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
        rl.set_shader_value(shader, emissive_color_location, floor_emissive, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)
        rl.set_shader_value(shader, metallic_value_location, unsafe: floor.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_METALNESS].value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.set_shader_value(shader, roughness_value_location, unsafe: floor.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_ROUGHNESS].value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.draw_model(floor, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 5.0, rl.WHITE)

        let car_emissive = color_vector(unsafe: car.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_EMISSION].color)
        let emissive_intensity: float = 0.01
        rl.set_shader_value(shader, texture_tiling_location, car_texture_tiling, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
        rl.set_shader_value(shader, emissive_color_location, car_emissive, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)
        rl.set_shader_value(shader, emissive_intensity_location, emissive_intensity, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.set_shader_value(shader, metallic_value_location, unsafe: car.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_METALNESS].value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.set_shader_value(shader, roughness_value_location, unsafe: car.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_ROUGHNESS].value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.draw_model(car, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 0.25, rl.WHITE)

        light_index = 0
        while light_index < MAX_LIGHTS:
            let display_color = light_display_color(lights[light_index])
            if lights[light_index].enabled:
                rl.draw_sphere_ex(lights[light_index].position, 0.2, 8, 8, display_color)
            else:
                rl.draw_sphere_wires(lights[light_index].position, 0.2, 8, 8, rl.color_alpha(display_color, 0.3))
            light_index += 1

        rl.end_mode_3d()
        rl.draw_text("Toggle lights: [1][2][3][4]", 10, 40, 20, rl.LIGHTGRAY)
        rl.draw_text("(c) Old Rusty Car model by Renafox (https://skfb.ly/LxRy)", SCREEN_WIDTH - 320, SCREEN_HEIGHT - 20, 10, rl.LIGHTGRAY)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
