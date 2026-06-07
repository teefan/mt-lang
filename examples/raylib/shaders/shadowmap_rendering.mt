import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.rlgl as rlgl
import std.raymath as rm

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const SHADOWMAP_RESOLUTION: int = 1024
const GLSL_VERSION: int = 330
const DEPTH_TEXTURE_FORMAT: int = 19


function color_vector(color: rl.Color) -> array[float, 4]:
    return array[float, 4](
        float<-color.r / 255.0,
        float<-color.g / 255.0,
        float<-color.b / 255.0,
        float<-color.a / 255.0
    )


function matrix_from_rlgl(matrix: rlgl.Matrix) -> rl.Matrix:
    return rl.Matrix(
        m0 = matrix.m0,
        m4 = matrix.m4,
        m8 = matrix.m8,
        m12 = matrix.m12,
        m1 = matrix.m1,
        m5 = matrix.m5,
        m9 = matrix.m9,
        m13 = matrix.m13,
        m2 = matrix.m2,
        m6 = matrix.m6,
        m10 = matrix.m10,
        m14 = matrix.m14,
        m3 = matrix.m3,
        m7 = matrix.m7,
        m11 = matrix.m11,
        m15 = matrix.m15
    )


function load_shadowmap_render_texture(width: int, height: int) -> rl.RenderTexture2D:
    var target = zero[rl.RenderTexture2D]
    target.id = rlgl.load_framebuffer()
    target.texture.width = width
    target.texture.height = height

    if target.id > uint<-0:
        rlgl.enable_framebuffer(target.id)
        target.depth = rl.Texture(
            id = rlgl.load_texture_depth(width, height, false),
            width = width,
            height = height,
            format = DEPTH_TEXTURE_FORMAT,
            mipmaps = 1
        )
        rlgl.framebuffer_attach(
            target.id,
            target.depth.id,
            int<-rlgl.FramebufferAttachType.RL_ATTACHMENT_DEPTH,
            int<-rlgl.FramebufferAttachTextureType.RL_ATTACHMENT_TEXTURE2D,
            0
        )
        if rlgl.framebuffer_complete(target.id):
            rl.trace_log(
                int<-rl.TraceLogLevel.LOG_INFO,
                "FBO: [ID %i] Framebuffer object created successfully",
                target.id
            )
        rlgl.disable_framebuffer()

    return target


function unload_shadowmap_render_texture(target: rl.RenderTexture2D) -> void:
    if target.id > uint<-0:
        rlgl.unload_framebuffer(target.id)


function draw_scene(cube: rl.Model, robot: rl.Model) -> void:
    rl.draw_model_ex(
        cube,
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        0.0,
        rl.Vector3(x = 10.0, y = 1.0, z = 10.0),
        rl.BLUE
    )
    rl.draw_model_ex(
        cube,
        rl.Vector3(x = 1.5, y = 1.0, z = -1.5),
        rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        0.0,
        rl.Vector3(x = 1.0, y = 1.0, z = 1.0),
        rl.WHITE
    )
    rl.draw_model_ex(
        robot,
        rl.Vector3(x = 0.0, y = 0.5, z = 0.0),
        rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        0.0,
        rl.Vector3(x = 1.0, y = 1.0, z = 1.0),
        rl.RED
    )


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - shadowmap rendering")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 10.0, y = 10.0, z = 10.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
        fovy = 45.0
    )

    var shadow_shader = rl.load_shader(
        rl.text_format("shaders/glsl%i/shadowmap.vs", GLSL_VERSION),
        rl.text_format("shaders/glsl%i/shadowmap.fs", GLSL_VERSION)
    )
    defer rl.unload_shader(shadow_shader)
    unsafe: shadow_shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW] = rl.get_shader_location(
        shadow_shader,
        "viewPos"
    )

    var light_dir = rm.vector3_normalize(rl.Vector3(x = 0.35, y = -1.0, z = -0.35))
    let light_color = color_vector(rl.WHITE)
    let light_dir_location = rl.get_shader_location(shadow_shader, "lightDir")
    let light_color_location = rl.get_shader_location(shadow_shader, "lightColor")
    let ambient_location = rl.get_shader_location(shadow_shader, "ambient")
    let light_vp_location = rl.get_shader_location(shadow_shader, "lightVP")
    let shadow_map_location = rl.get_shader_location(shadow_shader, "shadowMap")
    let shadow_map_resolution_location = rl.get_shader_location(shadow_shader, "shadowMapResolution")

    let initial_light_dir = array[float, 3](light_dir.x, light_dir.y, light_dir.z)
    let ambient = array[float, 4](0.1, 0.1, 0.1, 1.0)
    rl.set_shader_value(
        shadow_shader,
        light_dir_location,
        initial_light_dir,
        int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3
    )
    rl.set_shader_value(
        shadow_shader,
        light_color_location,
        light_color,
        int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4
    )
    rl.set_shader_value(shadow_shader, ambient_location, ambient, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)
    rl.set_shader_value(
        shadow_shader,
        shadow_map_resolution_location,
        SHADOWMAP_RESOLUTION,
        int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT
    )

    var cube = rl.load_model_from_mesh(rl.gen_mesh_cube(1.0, 1.0, 1.0))
    defer rl.unload_model(cube)
    unsafe: cube.materials[0].shader = shadow_shader

    var robot = rl.load_model("models/robot.glb")
    defer rl.unload_model(robot)
    var material_index = 0
    while material_index < robot.materialCount:
        unsafe: robot.materials[material_index].shader = shadow_shader
        material_index += 1

    var anim_count = 0
    let animations = rl.load_model_animations("models/robot.glb", ptr_of(anim_count)) else:
        fatal("could not load robot animations")
    defer rl.unload_model_animations(animations, anim_count)
    let animation = unsafe: animations[0]

    let shadow_map = load_shadowmap_render_texture(SHADOWMAP_RESOLUTION, SHADOWMAP_RESOLUTION)
    defer unload_shadowmap_render_texture(shadow_map)

    var light_camera = rl.Camera3D(
        position = rm.vector3_scale(light_dir, -15.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        projection = int<-rl.CameraProjection.CAMERA_ORTHOGRAPHIC,
        fovy = 20.0
    )

    var frame_counter = 0
    var light_view = zero[rl.Matrix]
    var light_proj = zero[rl.Matrix]
    var light_view_proj = zero[rl.Matrix]
    var texture_active_slot = 10

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let delta_time = rl.get_frame_time()
        let camera_position = array[float, 3](camera.position.x, camera.position.y, camera.position.z)
        rl.set_shader_value(
            shadow_shader,
            unsafe: shadow_shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW],
            camera_position,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3
        )
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        frame_counter = (frame_counter + 1) % animation.keyframeCount
        rl.update_model_animation(robot, animation, float<-frame_counter)

        let camera_speed: float = 0.05
        if rl.is_key_down(rl.KeyboardKey.KEY_LEFT) and light_dir.x < 0.6:
            light_dir.x += camera_speed * 60.0 * delta_time
        if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT) and light_dir.x > -0.6:
            light_dir.x -= camera_speed * 60.0 * delta_time
        if rl.is_key_down(rl.KeyboardKey.KEY_UP) and light_dir.z < 0.6:
            light_dir.z += camera_speed * 60.0 * delta_time
        if rl.is_key_down(rl.KeyboardKey.KEY_DOWN) and light_dir.z > -0.6:
            light_dir.z -= camera_speed * 60.0 * delta_time

        light_dir = rm.vector3_normalize(light_dir)
        light_camera.position = rm.vector3_scale(light_dir, -15.0)
        let light_dir_value = array[float, 3](light_dir.x, light_dir.y, light_dir.z)
        rl.set_shader_value(
            shadow_shader,
            light_dir_location,
            light_dir_value,
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3
        )

        rl.begin_texture_mode(shadow_map)
        rl.clear_background(rl.WHITE)
        rl.begin_mode_3d(light_camera)
        light_view = matrix_from_rlgl(rlgl.get_matrix_modelview())
        light_proj = matrix_from_rlgl(rlgl.get_matrix_projection())
        draw_scene(cube, robot)
        rl.end_mode_3d()
        rl.end_texture_mode()
        light_view_proj = rm.matrix_multiply(light_view, light_proj)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)
        rl.set_shader_value_matrix(shadow_shader, light_vp_location, light_view_proj)
        rlgl.enable_shader(shadow_shader.id)
        rlgl.active_texture_slot(texture_active_slot)
        rlgl.enable_texture(shadow_map.depth.id)
        rlgl.set_uniform(
            shadow_map_location,
            ptr_of(texture_active_slot),
            int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT,
            1
        )

        rl.begin_mode_3d(camera)
        draw_scene(cube, robot)
        rl.end_mode_3d()

        rlgl.disable_texture()
        rlgl.disable_shader()
        rl.draw_text("Use the arrow keys to rotate the light!", 10, 10, 30, rl.RED)
        rl.draw_text(
            "Shadows in raylib using the shadowmapping algorithm!",
            SCREEN_WIDTH - 280,
            SCREEN_HEIGHT - 20,
            10,
            rl.GRAY
        )
        rl.end_drawing()

        if rl.is_key_pressed(rl.KeyboardKey.KEY_F):
            rl.take_screenshot("shaders_shadowmap.png")

    return 0
