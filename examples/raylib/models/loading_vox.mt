import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as rm
import std.str as text


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_VOX_FILES: int = 4
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


function create_light(slot: int, light_type: int, position: rl.Vector3, target: rl.Vector3, color: rl.Color, shader: rl.Shader) -> Light:
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
        color_loc = rl.get_shader_location(shader, rl.text_format("lights[%i].color", slot)),
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
        float<-light.color.a / 255.0,
    )
    rl.set_shader_value(shader, light.color_loc, color_value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - loading vox")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    let vox_file_names = array[str, MAX_VOX_FILES](
        "models/vox/chr_knight.vox",
        "models/vox/chr_sword.vox",
        "models/vox/monu9.vox",
        "models/vox/fez.vox",
    )

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 10.0, y = 10.0, z = 10.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var models: array[rl.Model, MAX_VOX_FILES] = zero[array[rl.Model, MAX_VOX_FILES]]
    var model_index = 0
    while model_index < MAX_VOX_FILES:
        let start_time = rl.get_time() * 1000.0
        models[model_index] = rl.load_model(vox_file_names[model_index])
        let end_time = rl.get_time() * 1000.0
        rl.trace_log(int<-rl.TraceLogLevel.LOG_INFO, "[%s] Model file loaded in %.3f ms", vox_file_names[model_index], end_time - start_time)

        let bounds = rl.get_model_bounding_box(models[model_index])
        let center = rl.Vector3(
            x = bounds.min.x + (bounds.max.x - bounds.min.x) / 2.0,
            y = 0.0,
            z = bounds.min.z + (bounds.max.z - bounds.min.z) / 2.0,
        )
        models[model_index].transform = rm.matrix_translate(-center.x, 0.0, -center.z)
        model_index += 1

    defer:
        model_index = 0
        while model_index < MAX_VOX_FILES:
            rl.unload_model(models[model_index])
            model_index += 1

    var current_model = 0
    let model_position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
    var camera_rotation = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    let voxel_vertex_shader = rl.text_format("shaders/glsl%i/voxel_lighting.vs", GLSL_VERSION)
    let voxel_fragment_shader = rl.text_format("shaders/glsl%i/voxel_lighting.fs", GLSL_VERSION)
    var shader = rl.load_shader(voxel_vertex_shader, voxel_fragment_shader)
    defer rl.unload_shader(shader)

    unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW] = rl.get_shader_location(shader, "viewPos")

    let ambient_loc = rl.get_shader_location(shader, "ambient")
    let ambient = array[float, 4](0.1, 0.1, 0.1, 1.0)
    rl.set_shader_value(shader, ambient_loc, ambient, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)

    model_index = 0
    while model_index < MAX_VOX_FILES:
        var material_index = 0
        while material_index < models[model_index].materialCount:
            unsafe: models[model_index].materials[material_index].shader = shader
            material_index += 1
        model_index += 1

    var lights: array[Light, MAX_LIGHTS] = zero[array[Light, MAX_LIGHTS]]
    lights[0] = create_light(0, int<-LightType.LIGHT_POINT, rl.Vector3(x = -20.0, y = 20.0, z = -20.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.GRAY, shader)
    lights[1] = create_light(1, int<-LightType.LIGHT_POINT, rl.Vector3(x = 20.0, y = -20.0, z = 20.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.GRAY, shader)
    lights[2] = create_light(2, int<-LightType.LIGHT_POINT, rl.Vector3(x = -20.0, y = 20.0, z = 20.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.GRAY, shader)
    lights[3] = create_light(3, int<-LightType.LIGHT_POINT, rl.Vector3(x = 20.0, y = -20.0, z = -20.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.GRAY, shader)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_mouse_button_down(rl.MouseButton.MOUSE_BUTTON_MIDDLE):
            let mouse_delta = rl.get_mouse_delta()
            camera_rotation.x = mouse_delta.x * 0.05
            camera_rotation.y = mouse_delta.y * 0.05
        else:
            camera_rotation.x = 0.0
            camera_rotation.y = 0.0

        var movement_z = float<-0.0
        if rl.is_key_down(rl.KeyboardKey.KEY_W) or rl.is_key_down(rl.KeyboardKey.KEY_UP):
            movement_z += 0.1
        if rl.is_key_down(rl.KeyboardKey.KEY_S) or rl.is_key_down(rl.KeyboardKey.KEY_DOWN):
            movement_z -= 0.1

        var movement_x = float<-0.0
        if rl.is_key_down(rl.KeyboardKey.KEY_D) or rl.is_key_down(rl.KeyboardKey.KEY_RIGHT):
            movement_x += 0.1
        if rl.is_key_down(rl.KeyboardKey.KEY_A) or rl.is_key_down(rl.KeyboardKey.KEY_LEFT):
            movement_x -= 0.1

        rl.update_camera_pro(ptr_of(camera), rl.Vector3(x = movement_z, y = movement_x, z = 0.0), camera_rotation, rl.get_mouse_wheel_move() * -2.0)

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            current_model = (current_model + 1) % MAX_VOX_FILES

        let camera_pos = array[float, 3](camera.position.x, camera.position.y, camera.position.z)
        rl.set_shader_value(
            shader,
            unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW],
            camera_pos,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3,
        )

        var light_index = 0
        while light_index < MAX_LIGHTS:
            update_light_values(shader, lights[light_index])
            light_index += 1

        let current_vox_file = text.cstr_as_str(rl.get_file_name(vox_file_names[current_model]))
        let current_vox_text = rl.text_format("VOX model file: %s", current_vox_file)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_model(models[current_model], model_position, 1.0, rl.WHITE)
        rl.draw_grid(10, 1.0)

        light_index = 0
        while light_index < MAX_LIGHTS:
            if lights[light_index].enabled:
                rl.draw_sphere_ex(lights[light_index].position, 0.2, 8, 8, lights[light_index].color)
            else:
                rl.draw_sphere_wires(lights[light_index].position, 0.2, 8, 8, rl.color_alpha(lights[light_index].color, 0.3))
            light_index += 1
        rl.end_mode_3d()

        rl.draw_rectangle(10, 40, 340, 70, rl.fade(rl.SKYBLUE, 0.5))
        rl.draw_rectangle_lines(10, 40, 340, 70, rl.fade(rl.DARKBLUE, 0.5))
        rl.draw_text("- MOUSE LEFT BUTTON: CYCLE VOX MODELS", 20, 50, 10, rl.BLUE)
        rl.draw_text("- MOUSE MIDDLE BUTTON: ZOOM OR ROTATE CAMERA", 20, 70, 10, rl.BLUE)
        rl.draw_text("- UP-DOWN-LEFT-RIGHT KEYS: MOVE CAMERA", 20, 90, 10, rl.BLUE)
        rl.draw_text(current_vox_text, 10, 10, 20, rl.GRAY)
        rl.end_drawing()

    return 0
