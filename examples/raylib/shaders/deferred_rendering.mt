import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.rlgl as rlgl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_CUBES: int = 30
const MAX_LIGHTS: int = 4
const GLSL_VERSION: int = 330
const DEPTH_BUFFER_BIT: int = 0x00000100

struct GBuffer:
    framebuffer_id: uint
    position_texture_id: uint
    normal_texture_id: uint
    albedo_spec_texture_id: uint
    depth_renderbuffer_id: uint

enum DeferredMode: int
    DEFERRED_POSITION = 0
    DEFERRED_NORMAL = 1
    DEFERRED_ALBEDO = 2
    DEFERRED_SHADING = 3

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
    let position_value = array[float, 3](light.position.x, light.position.y, light.position.z)
    let target_value = array[float, 3](light.target.x, light.target.y, light.target.z)
    let color_value = array[float, 4](
        float<-light.color.r / 255.0,
        float<-light.color.g / 255.0,
        float<-light.color.b / 255.0,
        float<-light.color.a / 255.0
    )
    rl.set_shader_value(shader, light.enabled_loc, enabled_value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT)
    rl.set_shader_value(shader, light.type_loc, light.kind, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT)
    rl.set_shader_value(shader, light.position_loc, position_value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)
    rl.set_shader_value(shader, light.target_loc, target_value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC3)
    rl.set_shader_value(shader, light.color_loc, color_value, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_VEC4)


function gbuffer_texture(texture_id: uint) -> rl.Texture2D:
    return rl.Texture2D(id = texture_id, width = SCREEN_WIDTH, height = SCREEN_HEIGHT, mipmaps = 1, format = 0)


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - deferred rendering")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 5.0, y = 4.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 60.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    var model = rl.load_model_from_mesh(rl.gen_mesh_plane(10.0, 10.0, 3, 3))
    defer rl.unload_model(model)
    var cube = rl.load_model_from_mesh(rl.gen_mesh_cube(2.0, 2.0, 2.0))
    defer rl.unload_model(cube)

    let gbuffer_shader = rl.load_shader(
        rl.text_format("shaders/glsl%i/gbuffer.vs", GLSL_VERSION),
        rl.text_format("shaders/glsl%i/gbuffer.fs", GLSL_VERSION)
    )
    defer rl.unload_shader(gbuffer_shader)

    var deferred_shader = rl.load_shader(
        rl.text_format("shaders/glsl%i/deferred_shading.vs", GLSL_VERSION),
        rl.text_format("shaders/glsl%i/deferred_shading.fs", GLSL_VERSION)
    )
    defer rl.unload_shader(deferred_shader)
    unsafe: deferred_shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW] = rl.get_shader_location(
        deferred_shader,
        "viewPosition"
    )

    var gbuffer = GBuffer(
        framebuffer_id = rlgl.load_framebuffer(),
        position_texture_id = 0u,
        normal_texture_id = 0u,
        albedo_spec_texture_id = 0u,
        depth_renderbuffer_id = 0u
    )
    if gbuffer.framebuffer_id == 0u:
        rl.trace_log(int<-rl.TraceLogLevel.LOG_WARNING, "Failed to create framebufferId")

    rlgl.enable_framebuffer(gbuffer.framebuffer_id)
    gbuffer.position_texture_id = rlgl.load_texture(
        null,
        SCREEN_WIDTH,
        SCREEN_HEIGHT,
        int<-rlgl.PixelFormat.RL_PIXELFORMAT_UNCOMPRESSED_R16G16B16,
        1
    )
    gbuffer.normal_texture_id = rlgl.load_texture(
        null,
        SCREEN_WIDTH,
        SCREEN_HEIGHT,
        int<-rlgl.PixelFormat.RL_PIXELFORMAT_UNCOMPRESSED_R16G16B16,
        1
    )
    gbuffer.albedo_spec_texture_id = rlgl.load_texture(
        null,
        SCREEN_WIDTH,
        SCREEN_HEIGHT,
        int<-rlgl.PixelFormat.RL_PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
        1
    )

    rlgl.active_draw_buffers(3)
    rlgl.framebuffer_attach(
        gbuffer.framebuffer_id,
        gbuffer.position_texture_id,
        int<-rlgl.FramebufferAttachType.RL_ATTACHMENT_COLOR_CHANNEL0,
        int<-rlgl.FramebufferAttachTextureType.RL_ATTACHMENT_TEXTURE2D,
        0
    )
    rlgl.framebuffer_attach(
        gbuffer.framebuffer_id,
        gbuffer.normal_texture_id,
        int<-rlgl.FramebufferAttachType.RL_ATTACHMENT_COLOR_CHANNEL1,
        int<-rlgl.FramebufferAttachTextureType.RL_ATTACHMENT_TEXTURE2D,
        0
    )
    rlgl.framebuffer_attach(
        gbuffer.framebuffer_id,
        gbuffer.albedo_spec_texture_id,
        int<-rlgl.FramebufferAttachType.RL_ATTACHMENT_COLOR_CHANNEL2,
        int<-rlgl.FramebufferAttachTextureType.RL_ATTACHMENT_TEXTURE2D,
        0
    )
    gbuffer.depth_renderbuffer_id = rlgl.load_texture_depth(SCREEN_WIDTH, SCREEN_HEIGHT, true)
    rlgl.framebuffer_attach(
        gbuffer.framebuffer_id,
        gbuffer.depth_renderbuffer_id,
        int<-rlgl.FramebufferAttachType.RL_ATTACHMENT_DEPTH,
        int<-rlgl.FramebufferAttachTextureType.RL_ATTACHMENT_RENDERBUFFER,
        0
    )
    if not rlgl.framebuffer_complete(gbuffer.framebuffer_id):
        rl.trace_log(int<-rl.TraceLogLevel.LOG_WARNING, "Framebuffer is not complete")

    rlgl.enable_shader(deferred_shader.id)
    let tex_unit_position = 0
    let tex_unit_normal = 1
    let tex_unit_albedo_spec = 2
    rl.set_shader_value(
        deferred_shader,
        rlgl.get_location_uniform(deferred_shader.id, "gPosition"),
        tex_unit_position,
        int<-rl.ShaderUniformDataType.SHADER_UNIFORM_SAMPLER2D
    )
    rl.set_shader_value(
        deferred_shader,
        rlgl.get_location_uniform(deferred_shader.id, "gNormal"),
        tex_unit_normal,
        int<-rl.ShaderUniformDataType.SHADER_UNIFORM_SAMPLER2D
    )
    rl.set_shader_value(
        deferred_shader,
        rlgl.get_location_uniform(deferred_shader.id, "gAlbedoSpec"),
        tex_unit_albedo_spec,
        int<-rl.ShaderUniformDataType.SHADER_UNIFORM_SAMPLER2D
    )
    rlgl.disable_shader()

    unsafe: model.materials[0].shader = gbuffer_shader
    unsafe: cube.materials[0].shader = gbuffer_shader

    var lights: array[Light, MAX_LIGHTS] = zero[array[Light, MAX_LIGHTS]]
    lights[0] = create_light(
        0,
        int<-LightType.LIGHT_POINT,
        rl.Vector3(x = -2.0, y = 1.0, z = -2.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.YELLOW,
        deferred_shader
    )
    lights[1] = create_light(
        1,
        int<-LightType.LIGHT_POINT,
        rl.Vector3(x = 2.0, y = 1.0, z = 2.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.RED,
        deferred_shader
    )
    lights[2] = create_light(
        2,
        int<-LightType.LIGHT_POINT,
        rl.Vector3(x = -2.0, y = 1.0, z = 2.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.GREEN,
        deferred_shader
    )
    lights[3] = create_light(
        3,
        int<-LightType.LIGHT_POINT,
        rl.Vector3(x = 2.0, y = 1.0, z = -2.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.BLUE,
        deferred_shader
    )

    let cube_scale: float = 0.25
    var cube_positions: array[rl.Vector3, MAX_CUBES] = zero[array[rl.Vector3, MAX_CUBES]]
    var cube_rotations: array[float, MAX_CUBES] = zero[array[float, MAX_CUBES]]
    var cube_index = 0
    while cube_index < MAX_CUBES:
        cube_positions[cube_index] = rl.Vector3(
            x = float<-rl.get_random_value(0, 9) - 5.0,
            y = float<-rl.get_random_value(0, 4),
            z = float<-rl.get_random_value(0, 9) - 5.0
        )
        cube_rotations[cube_index] = float<-rl.get_random_value(0, 359)
        cube_index += 1

    var mode = int<-DeferredMode.DEFERRED_SHADING
    rlgl.enable_depth_test()
    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)
        let camera_position = array[float, 3](camera.position.x, camera.position.y, camera.position.z)
        rl.set_shader_value(
            deferred_shader,
            unsafe: deferred_shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_VECTOR_VIEW],
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

        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            mode = int<-DeferredMode.DEFERRED_POSITION
        if rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            mode = int<-DeferredMode.DEFERRED_NORMAL
        if rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            mode = int<-DeferredMode.DEFERRED_ALBEDO
        if rl.is_key_pressed(rl.KeyboardKey.KEY_FOUR):
            mode = int<-DeferredMode.DEFERRED_SHADING

        var light_index = 0
        while light_index < MAX_LIGHTS:
            update_light_values(deferred_shader, lights[light_index])
            light_index += 1

        rl.begin_drawing()
        rlgl.enable_framebuffer(gbuffer.framebuffer_id)
        rlgl.clear_color(0, 0, 0, 0)
        rlgl.clear_screen_buffers()
        rlgl.disable_color_blend()

        rl.begin_mode_3d(camera)
        rlgl.enable_shader(gbuffer_shader.id)
        rl.draw_model(model, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 1.0, rl.WHITE)
        rl.draw_model(cube, rl.Vector3(x = 0.0, y = 1.0, z = 0.0), 1.0, rl.WHITE)

        cube_index = 0
        while cube_index < MAX_CUBES:
            rl.draw_model_ex(
                cube,
                cube_positions[cube_index],
                rl.Vector3(x = 1.0, y = 1.0, z = 1.0),
                cube_rotations[cube_index],
                rl.Vector3(x = cube_scale, y = cube_scale, z = cube_scale),
                rl.WHITE
            )
            cube_index += 1
        rlgl.disable_shader()
        rl.end_mode_3d()

        rlgl.enable_color_blend()
        rlgl.disable_framebuffer()
        rlgl.clear_screen_buffers()

        if mode == int<-DeferredMode.DEFERRED_SHADING:
            rl.begin_mode_3d(camera)
            rlgl.disable_color_blend()
            rlgl.enable_shader(deferred_shader.id)
            rlgl.active_texture_slot(tex_unit_position)
            rlgl.enable_texture(gbuffer.position_texture_id)
            rlgl.active_texture_slot(tex_unit_normal)
            rlgl.enable_texture(gbuffer.normal_texture_id)
            rlgl.active_texture_slot(tex_unit_albedo_spec)
            rlgl.enable_texture(gbuffer.albedo_spec_texture_id)
            rlgl.load_draw_quad()
            rlgl.disable_shader()
            rlgl.enable_color_blend()
            rl.end_mode_3d()

            rlgl.bind_framebuffer(uint<-rlgl.RL_READ_FRAMEBUFFER, gbuffer.framebuffer_id)
            rlgl.bind_framebuffer(uint<-rlgl.RL_DRAW_FRAMEBUFFER, 0u)
            rlgl.blit_framebuffer(
                0,
                0,
                SCREEN_WIDTH,
                SCREEN_HEIGHT,
                0,
                0,
                SCREEN_WIDTH,
                SCREEN_HEIGHT,
                DEPTH_BUFFER_BIT
            )
            rlgl.disable_framebuffer()

            rl.begin_mode_3d(camera)
            rlgl.enable_shader(rlgl.get_shader_id_default())
            light_index = 0
            while light_index < MAX_LIGHTS:
                if lights[light_index].enabled:
                    rl.draw_sphere_ex(lights[light_index].position, 0.2, 8, 8, lights[light_index].color)
                else:
                    rl.draw_sphere_wires(
                        lights[light_index].position,
                        0.2,
                        8,
                        8,
                        rl.color_alpha(lights[light_index].color, 0.3)
                    )
                light_index += 1
            rlgl.disable_shader()
            rl.end_mode_3d()

            rl.draw_text("FINAL RESULT", 10, SCREEN_HEIGHT - 30, 20, rl.DARKGREEN)
        else if mode == int<-DeferredMode.DEFERRED_POSITION:
            rl.draw_texture_rec(
                gbuffer_texture(gbuffer.position_texture_id),
                rl.Rectangle(x = 0.0, y = 0.0, width = float<-SCREEN_WIDTH, height = -(float<-SCREEN_HEIGHT)),
                rl.Vector2(x = 0.0, y = 0.0),
                rl.RAYWHITE
            )
            rl.draw_text("POSITION TEXTURE", 10, SCREEN_HEIGHT - 30, 20, rl.DARKGREEN)
        else if mode == int<-DeferredMode.DEFERRED_NORMAL:
            rl.draw_texture_rec(
                gbuffer_texture(gbuffer.normal_texture_id),
                rl.Rectangle(x = 0.0, y = 0.0, width = float<-SCREEN_WIDTH, height = -(float<-SCREEN_HEIGHT)),
                rl.Vector2(x = 0.0, y = 0.0),
                rl.RAYWHITE
            )
            rl.draw_text("NORMAL TEXTURE", 10, SCREEN_HEIGHT - 30, 20, rl.DARKGREEN)
        else if mode == int<-DeferredMode.DEFERRED_ALBEDO:
            rl.draw_texture_rec(
                gbuffer_texture(gbuffer.albedo_spec_texture_id),
                rl.Rectangle(x = 0.0, y = 0.0, width = float<-SCREEN_WIDTH, height = -(float<-SCREEN_HEIGHT)),
                rl.Vector2(x = 0.0, y = 0.0),
                rl.RAYWHITE
            )
            rl.draw_text("ALBEDO TEXTURE", 10, SCREEN_HEIGHT - 30, 20, rl.DARKGREEN)

        rl.draw_text("Toggle lights keys: [Y][R][G][B]", 10, 40, 20, rl.DARKGRAY)
        rl.draw_text("Switch G-buffer textures: [1][2][3][4]", 10, 70, 20, rl.DARKGRAY)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
