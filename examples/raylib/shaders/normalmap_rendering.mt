import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as rm


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - normalmap rendering")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 0.0, y = 2.0, z = -4.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var shader = rl.load_shader(
        rl.text_format("shaders/glsl%i/normalmap.vs", GLSL_VERSION),
        rl.text_format("shaders/glsl%i/normalmap.fs", GLSL_VERSION),
    )
    defer rl.unload_shader(shader)
    unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_MAP_NORMAL] = rl.get_shader_location(shader, "normalMap")
    unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW] = rl.get_shader_location(shader, "viewPos")

    var light_position = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
    let light_position_location = rl.get_shader_location(shader, "lightPos")

    var plane = rl.load_model("models/plane.glb")
    defer rl.unload_model(plane)
    unsafe: plane.materials[0].shader = shader

    var diffuse_texture = rl.load_texture("tiles_diffuse.png")
    defer rl.unload_texture(diffuse_texture)
    var normal_texture = rl.load_texture("tiles_normal.png")
    defer rl.unload_texture(normal_texture)

    rl.gen_texture_mipmaps(diffuse_texture)
    rl.gen_texture_mipmaps(normal_texture)
    rl.set_texture_filter(diffuse_texture, int<-rl.TextureFilter.TEXTURE_FILTER_TRILINEAR)
    rl.set_texture_filter(normal_texture, int<-rl.TextureFilter.TEXTURE_FILTER_TRILINEAR)
    rl.set_material_texture(plane.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, diffuse_texture)
    rl.set_material_texture(plane.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_NORMAL, normal_texture)

    var specular_exponent: float = 8.0
    let specular_exponent_location = rl.get_shader_location(shader, "specularExponent")
    var use_normal_map = 1
    let use_normal_map_location = rl.get_shader_location(shader, "useNormalMap")

    rl.set_target_fps(60)

    while not rl.window_should_close():
        var direction = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
        if rl.is_key_down(rl.KeyboardKey.KEY_W):
            direction = rm.vector3_add(direction, rl.Vector3(x = 0.0, y = 0.0, z = 1.0))
        if rl.is_key_down(rl.KeyboardKey.KEY_S):
            direction = rm.vector3_add(direction, rl.Vector3(x = 0.0, y = 0.0, z = -1.0))
        if rl.is_key_down(rl.KeyboardKey.KEY_D):
            direction = rm.vector3_add(direction, rl.Vector3(x = -1.0, y = 0.0, z = 0.0))
        if rl.is_key_down(rl.KeyboardKey.KEY_A):
            direction = rm.vector3_add(direction, rl.Vector3(x = 1.0, y = 0.0, z = 0.0))

        direction = rm.vector3_normalize(direction)
        light_position = rm.vector3_add(light_position, rm.vector3_scale(direction, rl.get_frame_time() * 3.0))

        if rl.is_key_down(rl.KeyboardKey.KEY_UP):
            specular_exponent = rm.clamp(specular_exponent + 40.0 * rl.get_frame_time(), 2.0, 128.0)
        if rl.is_key_down(rl.KeyboardKey.KEY_DOWN):
            specular_exponent = rm.clamp(specular_exponent - 40.0 * rl.get_frame_time(), 2.0, 128.0)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_N):
            use_normal_map = if use_normal_map == 0: 1 else: 0

        plane.transform = rm.matrix_rotate_y(float<-(rl.get_time() * 0.5))

        let light_position_value = array[float, 3](light_position.x, light_position.y, light_position.z)
        let camera_position = array[float, 3](camera.position.x, camera.position.y, camera.position.z)
        rl.set_shader_value(shader, light_position_location, light_position_value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)
        rl.set_shader_value(
            shader,
            unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW],
            camera_position,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3,
        )
        rl.set_shader_value(shader, specular_exponent_location, specular_exponent, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_FLOAT)
        rl.set_shader_value(shader, use_normal_map_location, use_normal_map, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.begin_shader_mode(shader)
        rl.draw_model(plane, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 2.0, rl.WHITE)
        rl.end_shader_mode()
        rl.draw_sphere_wires(light_position, 0.2, 8, 8, rl.ORANGE)
        rl.end_mode_3d()

        let toggle_text = if use_normal_map == 0: "Off" else: "On"
        let toggle_color = if use_normal_map == 0: rl.RED else: rl.DARKGREEN
        rl.draw_text(rl.text_format("Use key [N] to toggle normal map: %s", toggle_text), 10, 10, 10, toggle_color)
        rl.draw_text("Use keys [W][A][S][D] to move the light", 10, 34, 10, rl.BLACK)
        rl.draw_text("Use keys [Up][Down] to change specular exponent", 10, 58, 10, rl.BLACK)
        rl.draw_text(rl.text_format("Specular Exponent: %.2f", specular_exponent), 10, 82, 10, rl.BLUE)
        rl.draw_fps(SCREEN_WIDTH - 90, 10)
        rl.end_drawing()

    return 0
