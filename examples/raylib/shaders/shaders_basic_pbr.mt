module examples.raylib.shaders.shaders_basic_pbr

import std.c.raylib as rl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const max_lights: i32 = 4
const shader_vertex_path_format: cstr = c"../resources/shaders/glsl%i/pbr.vs"
const shader_fragment_path_format: cstr = c"../resources/shaders/glsl%i/pbr.fs"
const car_model_path: cstr = c"../resources/models/old_car_new.glb"
const floor_model_path: cstr = c"../resources/models/plane.glb"
const car_albedo_path: cstr = c"../resources/old_car_d.png"
const car_mra_path: cstr = c"../resources/old_car_mra.png"
const car_normal_path: cstr = c"../resources/old_car_n.png"
const car_emission_path: cstr = c"../resources/old_car_e.png"
const floor_albedo_path: cstr = c"../resources/road_a.png"
const floor_mra_path: cstr = c"../resources/road_mra.png"
const floor_normal_path: cstr = c"../resources/road_n.png"
const albedo_map_uniform_name: cstr = c"albedoMap"
const mra_map_uniform_name: cstr = c"mraMap"
const normal_map_uniform_name: cstr = c"normalMap"
const emissive_map_uniform_name: cstr = c"emissiveMap"
const albedo_color_uniform_name: cstr = c"albedoColor"
const view_pos_uniform_name: cstr = c"viewPos"
const light_count_uniform_name: cstr = c"numOfLights"
const ambient_color_uniform_name: cstr = c"ambientColor"
const ambient_uniform_name: cstr = c"ambient"
const metallic_value_uniform_name: cstr = c"metallicValue"
const roughness_value_uniform_name: cstr = c"roughnessValue"
const emissive_intensity_uniform_name: cstr = c"emissivePower"
const emissive_color_uniform_name: cstr = c"emissiveColor"
const texture_tiling_uniform_name: cstr = c"tiling"
const use_tex_albedo_uniform_name: cstr = c"useTexAlbedo"
const use_tex_normal_uniform_name: cstr = c"useTexNormal"
const use_tex_mra_uniform_name: cstr = c"useTexMRA"
const use_tex_emissive_uniform_name: cstr = c"useTexEmissive"
const help_text: cstr = c"Toggle lights: [1][2][3][4]"
const credit_text: cstr = c"(c) Old Rusty Car model by Renafox (https://skfb.ly/LxRy)"
const light_enabled_format: cstr = c"lights[%i].enabled"
const light_type_format: cstr = c"lights[%i].kind"
const light_position_format: cstr = c"lights[%i].position"
const light_target_format: cstr = c"lights[%i].target"
const light_color_format: cstr = c"lights[%i].color"
const light_intensity_format: cstr = c"lights[%i].intensity"
const window_title: cstr = c"raylib [shaders] example - basic pbr"

enum LightType: i32
    LIGHT_DIRECTIONAL = 0
    LIGHT_POINT = 1
    LIGHT_SPOT = 2

struct Light:
    kind: i32
    enabled: i32
    position: rl.Vector3
    target: rl.Vector3
    color: array[f32, 4]
    intensity: f32
    type_loc: i32
    enabled_loc: i32
    position_loc: i32
    target_loc: i32
    color_loc: i32
    intensity_loc: i32

var light_count: i32 = 0


def set_model_shader(model: ptr[rl.Model], shader: rl.Shader) -> void:
    unsafe:
        model.materials[0].shader = shader


def set_material_map_color(materials: ptr[rl.Material], map_index: i32, color: rl.Color) -> void:
    unsafe:
        materials.maps[map_index].color = color


def set_material_map_value(materials: ptr[rl.Material], map_index: i32, value: f32) -> void:
    unsafe:
        materials.maps[map_index].value = value


def set_shader_int(shader: rl.Shader, location: i32, value: i32) -> void:
    var storage = value
    rl.SetShaderValue(shader, location, ptr_of(ref_of(storage)), rl.ShaderUniformDataType.SHADER_UNIFORM_INT)


def update_light(shader: rl.Shader, light: Light) -> void:
    var enabled = light.enabled
    var type_value = light.kind
    var position = array[f32, 3](light.position.x, light.position.y, light.position.z)
    var target = array[f32, 3](light.target.x, light.target.y, light.target.z)
    var color = array[f32, 4](light.color[0], light.color[1], light.color[2], light.color[3])
    var intensity = light.intensity

    rl.SetShaderValue(shader, light.enabled_loc, ptr_of(ref_of(enabled)), rl.ShaderUniformDataType.SHADER_UNIFORM_INT)
    rl.SetShaderValue(shader, light.type_loc, ptr_of(ref_of(type_value)), rl.ShaderUniformDataType.SHADER_UNIFORM_INT)
    rl.SetShaderValue(shader, light.position_loc, ptr_of(ref_of(position[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)
    rl.SetShaderValue(shader, light.target_loc, ptr_of(ref_of(target[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)
    rl.SetShaderValue(shader, light.color_loc, ptr_of(ref_of(color[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)
    rl.SetShaderValue(shader, light.intensity_loc, ptr_of(ref_of(intensity)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)


def create_light(kind: i32, position: rl.Vector3, target: rl.Vector3, color: rl.Color, intensity: f32, shader: rl.Shader) -> Light:
    var light = Light(
        kind = 0,
        enabled = 0,
        position = rm.Vector3.zero(),
        target = rm.Vector3.zero(),
        color = array[f32, 4](0.0, 0.0, 0.0, 0.0),
        intensity = 0.0,
        type_loc = 0,
        enabled_loc = 0,
        position_loc = 0,
        target_loc = 0,
        color_loc = 0,
        intensity_loc = 0,
    )

    if light_count < max_lights:
        light.enabled = 1
        light.kind = kind
        light.position = position
        light.target = target
        light.color[0] = f32<-color.r / 255.0
        light.color[1] = f32<-color.g / 255.0
        light.color[2] = f32<-color.b / 255.0
        light.color[3] = f32<-color.a / 255.0
        light.intensity = intensity

        light.enabled_loc = rl.GetShaderLocation(shader, rl.TextFormat(light_enabled_format, light_count))
        light.type_loc = rl.GetShaderLocation(shader, rl.TextFormat(light_type_format, light_count))
        light.position_loc = rl.GetShaderLocation(shader, rl.TextFormat(light_position_format, light_count))
        light.target_loc = rl.GetShaderLocation(shader, rl.TextFormat(light_target_format, light_count))
        light.color_loc = rl.GetShaderLocation(shader, rl.TextFormat(light_color_format, light_count))
        light.intensity_loc = rl.GetShaderLocation(shader, rl.TextFormat(light_intensity_format, light_count))

        update_light(shader, light)
        light_count += 1

    return light


def light_display_color(light: Light) -> rl.Color:
    return rl.Color(
        r = u8<-(light.color[0] * 255.0),
        g = u8<-(light.color[1] * 255.0),
        b = u8<-(light.color[2] * 255.0),
        a = u8<-(light.color[3] * 255.0),
    )


def main() -> i32:
    light_count = 0

    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 2.0, y = 2.0, z = 6.0),
        target = rl.Vector3(x = 0.0, y = 0.5, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var shader = rl.LoadShader(
        rl.TextFormat(shader_vertex_path_format, glsl_version),
        rl.TextFormat(shader_fragment_path_format, glsl_version),
    )
    defer rl.UnloadShader(shader)

    unsafe:
        shader.locs[i32<-rl.ShaderLocationIndex.SHADER_LOC_MAP_ALBEDO] = rl.GetShaderLocation(shader, albedo_map_uniform_name)
        shader.locs[i32<-rl.ShaderLocationIndex.SHADER_LOC_MAP_METALNESS] = rl.GetShaderLocation(shader, mra_map_uniform_name)
        shader.locs[i32<-rl.ShaderLocationIndex.SHADER_LOC_MAP_NORMAL] = rl.GetShaderLocation(shader, normal_map_uniform_name)
        shader.locs[i32<-rl.ShaderLocationIndex.SHADER_LOC_MAP_EMISSION] = rl.GetShaderLocation(shader, emissive_map_uniform_name)
        shader.locs[i32<-rl.ShaderLocationIndex.SHADER_LOC_COLOR_DIFFUSE] = rl.GetShaderLocation(shader, albedo_color_uniform_name)
        shader.locs[i32<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW] = rl.GetShaderLocation(shader, view_pos_uniform_name)

    let light_count_loc = rl.GetShaderLocation(shader, light_count_uniform_name)
    set_shader_int(shader, light_count_loc, max_lights)

    var ambient_color = array[f32, 3](26.0 / 255.0, 32.0 / 255.0, 135.0 / 255.0)
    let ambient_intensity_loc = rl.GetShaderLocation(shader, ambient_uniform_name)
    let ambient_color_loc = rl.GetShaderLocation(shader, ambient_color_uniform_name)
    var ambient_intensity: f32 = 0.02
    rl.SetShaderValue(shader, ambient_color_loc, ptr_of(ref_of(ambient_color[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)
    rl.SetShaderValue(shader, ambient_intensity_loc, ptr_of(ref_of(ambient_intensity)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)

    let metallic_value_loc = rl.GetShaderLocation(shader, metallic_value_uniform_name)
    let roughness_value_loc = rl.GetShaderLocation(shader, roughness_value_uniform_name)
    let emissive_intensity_loc = rl.GetShaderLocation(shader, emissive_intensity_uniform_name)
    let emissive_color_loc = rl.GetShaderLocation(shader, emissive_color_uniform_name)
    let texture_tiling_loc = rl.GetShaderLocation(shader, texture_tiling_uniform_name)

    var car = rl.LoadModel(car_model_path)
    defer rl.UnloadModel(car)
    set_model_shader(ptr_of(ref_of(car)), shader)

    set_material_map_color(car.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, rl.WHITE)
    set_material_map_value(car.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_METALNESS, 1.0)
    set_material_map_value(car.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_ROUGHNESS, 0.0)
    set_material_map_value(car.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_OCCLUSION, 1.0)
    let car_emissive_color = rl.Color(r = 255, g = 162, b = 0, a = 255)
    set_material_map_color(car.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_EMISSION, car_emissive_color)

    let car_albedo_texture = rl.LoadTexture(car_albedo_path)
    defer rl.UnloadTexture(car_albedo_texture)
    let car_mra_texture = rl.LoadTexture(car_mra_path)
    defer rl.UnloadTexture(car_mra_texture)
    let car_normal_texture = rl.LoadTexture(car_normal_path)
    defer rl.UnloadTexture(car_normal_texture)
    let car_emission_texture = rl.LoadTexture(car_emission_path)
    defer rl.UnloadTexture(car_emission_texture)
    rl.SetMaterialTexture(car.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, car_albedo_texture)
    rl.SetMaterialTexture(car.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_METALNESS, car_mra_texture)
    rl.SetMaterialTexture(car.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_NORMAL, car_normal_texture)
    rl.SetMaterialTexture(car.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_EMISSION, car_emission_texture)

    var floor = rl.LoadModel(floor_model_path)
    defer rl.UnloadModel(floor)
    set_model_shader(ptr_of(ref_of(floor)), shader)

    set_material_map_color(floor.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, rl.WHITE)
    set_material_map_value(floor.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_METALNESS, 0.8)
    set_material_map_value(floor.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_ROUGHNESS, 0.1)
    set_material_map_value(floor.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_OCCLUSION, 1.0)
    let floor_emissive_color = rl.BLACK
    set_material_map_color(floor.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_EMISSION, floor_emissive_color)

    let floor_albedo_texture = rl.LoadTexture(floor_albedo_path)
    defer rl.UnloadTexture(floor_albedo_texture)
    let floor_mra_texture = rl.LoadTexture(floor_mra_path)
    defer rl.UnloadTexture(floor_mra_texture)
    let floor_normal_texture = rl.LoadTexture(floor_normal_path)
    defer rl.UnloadTexture(floor_normal_texture)
    rl.SetMaterialTexture(floor.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, floor_albedo_texture)
    rl.SetMaterialTexture(floor.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_METALNESS, floor_mra_texture)
    rl.SetMaterialTexture(floor.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_NORMAL, floor_normal_texture)

    var car_texture_tiling = array[f32, 2](0.5, 0.5)
    var floor_texture_tiling = array[f32, 2](0.5, 0.5)
    var car_metallic_value: f32 = 1.0
    var car_roughness_value: f32 = 0.0
    var floor_metallic_value: f32 = 0.8
    var floor_roughness_value: f32 = 0.1
    var emissive_intensity: f32 = 0.01
    var car_emissive = array[f32, 4](1.0, 162.0 / 255.0, 0.0, 1.0)
    var floor_emissive = array[f32, 4](0.0, 0.0, 0.0, 1.0)

    var light_sources = zero[array[Light, 4]]()
    light_sources[0] = create_light(i32<-LightType.LIGHT_POINT, rl.Vector3(x = -1.0, y = 1.0, z = -2.0), rm.Vector3.zero(), rl.YELLOW, 4.0, shader)
    light_sources[1] = create_light(i32<-LightType.LIGHT_POINT, rl.Vector3(x = 2.0, y = 1.0, z = 1.0), rm.Vector3.zero(), rl.GREEN, 3.3, shader)
    light_sources[2] = create_light(i32<-LightType.LIGHT_POINT, rl.Vector3(x = -2.0, y = 1.0, z = 1.0), rm.Vector3.zero(), rl.RED, 8.3, shader)
    light_sources[3] = create_light(i32<-LightType.LIGHT_POINT, rl.Vector3(x = 1.0, y = 1.0, z = -2.0), rm.Vector3.zero(), rl.BLUE, 2.0, shader)

    let usage = 1
    set_shader_int(shader, rl.GetShaderLocation(shader, use_tex_albedo_uniform_name), usage)
    set_shader_int(shader, rl.GetShaderLocation(shader, use_tex_normal_uniform_name), usage)
    set_shader_int(shader, rl.GetShaderLocation(shader, use_tex_mra_uniform_name), usage)
    set_shader_int(shader, rl.GetShaderLocation(shader, use_tex_emissive_uniform_name), usage)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(ref_of(camera)), rl.CameraMode.CAMERA_ORBITAL)

        var camera_pos = array[f32, 3](camera.position.x, camera.position.y, camera.position.z)
        unsafe:
            rl.SetShaderValue(
                shader,
                read(shader.locs + usize<-(i32<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW)),
                ptr_of(ref_of(camera_pos[0])),
                rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3,
            )

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_ONE):
            light_sources[2].enabled = 1 - light_sources[2].enabled
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_TWO):
            light_sources[1].enabled = 1 - light_sources[1].enabled
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_THREE):
            light_sources[3].enabled = 1 - light_sources[3].enabled
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_FOUR):
            light_sources[0].enabled = 1 - light_sources[0].enabled

        for light_index in 0..max_lights:
            update_light(shader, light_sources[light_index])

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)

        rl.BeginMode3D(camera)

        rl.SetShaderValue(shader, texture_tiling_loc, ptr_of(ref_of(floor_texture_tiling[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
        rl.SetShaderValue(shader, emissive_color_loc, ptr_of(ref_of(floor_emissive[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)
        rl.SetShaderValue(shader, metallic_value_loc, ptr_of(ref_of(floor_metallic_value)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.SetShaderValue(shader, roughness_value_loc, ptr_of(ref_of(floor_roughness_value)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.DrawModel(floor, rm.Vector3.zero(), 5.0, rl.WHITE)

        rl.SetShaderValue(shader, texture_tiling_loc, ptr_of(ref_of(car_texture_tiling[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC2)
        rl.SetShaderValue(shader, emissive_color_loc, ptr_of(ref_of(car_emissive[0])), rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)
        rl.SetShaderValue(shader, emissive_intensity_loc, ptr_of(ref_of(emissive_intensity)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.SetShaderValue(shader, metallic_value_loc, ptr_of(ref_of(car_metallic_value)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.SetShaderValue(shader, roughness_value_loc, ptr_of(ref_of(car_roughness_value)), rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.DrawModel(car, rm.Vector3.zero(), 0.25, rl.WHITE)

        for light_index in 0..max_lights:
            let light_color = light_display_color(light_sources[light_index])
            if light_sources[light_index].enabled != 0:
                rl.DrawSphereEx(light_sources[light_index].position, 0.2, 8, 8, light_color)
            else:
                rl.DrawSphereWires(light_sources[light_index].position, 0.2, 8, 8, rl.ColorAlpha(light_color, 0.3))

        rl.EndMode3D()

        rl.DrawText(help_text, 10, 40, 20, rl.LIGHTGRAY)
        rl.DrawText(credit_text, screen_width - 320, screen_height - 20, 10, rl.LIGHTGRAY)
        rl.DrawFPS(10, 10)

    return 0
