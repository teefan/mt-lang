import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.raymath as rm
import std.rlgl as rlgl
import std.str as text

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330
const DEG_TO_RAD: double = 3.141592653589793 / 180.0


function gen_texture_cubemap(shader: rl.Shader, panorama: rl.Texture2D, size: int, format: int) -> rl.TextureCubemap:
    var cubemap = zero[rl.TextureCubemap]

    rlgl.disable_backface_culling()

    let depth_buffer = rlgl.load_texture_depth(size, size, true)
    cubemap.id = rlgl.load_texture_cubemap(null, size, format, 1)

    let framebuffer = rlgl.load_framebuffer()
    rlgl.framebuffer_attach(
        framebuffer,
        depth_buffer,
        int<-rlgl.FramebufferAttachType.RL_ATTACHMENT_DEPTH,
        int<-rlgl.FramebufferAttachTextureType.RL_ATTACHMENT_RENDERBUFFER,
        0
    )
    rlgl.framebuffer_attach(
        framebuffer,
        cubemap.id,
        int<-rlgl.FramebufferAttachType.RL_ATTACHMENT_COLOR_CHANNEL0,
        int<-rlgl.FramebufferAttachTextureType.RL_ATTACHMENT_CUBEMAP_POSITIVE_X,
        0
    )

    if rlgl.framebuffer_complete(framebuffer):
        rl.trace_log(
            int<-rl.TraceLogLevel.LOG_INFO,
            "FBO: [ID %i] Framebuffer object created successfully",
            framebuffer
        )

    rlgl.enable_shader(shader.id)

    let projection = rm.matrix_perspective(
        90.0 * DEG_TO_RAD,
        1.0,
        rlgl.get_cull_distance_near(),
        rlgl.get_cull_distance_far()
    )
    rl.set_shader_value_matrix(
        shader,
        unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_MATRIX_PROJECTION],
        projection
    )

    let views = array[rl.Matrix, 6](
        rm.matrix_look_at(
            rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
            rl.Vector3(x = 1.0, y = 0.0, z = 0.0),
            rl.Vector3(x = 0.0, y = -1.0, z = 0.0)
        ),
        rm.matrix_look_at(
            rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
            rl.Vector3(x = -1.0, y = 0.0, z = 0.0),
            rl.Vector3(x = 0.0, y = -1.0, z = 0.0)
        ),
        rm.matrix_look_at(
            rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
            rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
            rl.Vector3(x = 0.0, y = 0.0, z = 1.0)
        ),
        rm.matrix_look_at(
            rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
            rl.Vector3(x = 0.0, y = -1.0, z = 0.0),
            rl.Vector3(x = 0.0, y = 0.0, z = -1.0)
        ),
        rm.matrix_look_at(
            rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
            rl.Vector3(x = 0.0, y = 0.0, z = 1.0),
            rl.Vector3(x = 0.0, y = -1.0, z = 0.0)
        ),
        rm.matrix_look_at(
            rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
            rl.Vector3(x = 0.0, y = 0.0, z = -1.0),
            rl.Vector3(x = 0.0, y = -1.0, z = 0.0)
        )
    )

    rlgl.viewport(0, 0, size, size)
    rlgl.active_texture_slot(0)
    rlgl.enable_texture(panorama.id)

    var face = 0
    while face < 6:
        rl.set_shader_value_matrix(
            shader,
            unsafe: shader.locs[int<-rl.ShaderLocationIndex.SHADER_LOC_MATRIX_VIEW],
            views[face]
        )
        rlgl.framebuffer_attach(
            framebuffer,
            cubemap.id,
            int<-rlgl.FramebufferAttachType.RL_ATTACHMENT_COLOR_CHANNEL0,
            int<-rlgl.FramebufferAttachTextureType.RL_ATTACHMENT_CUBEMAP_POSITIVE_X + face,
            0
        )
        rlgl.enable_framebuffer(framebuffer)
        rlgl.clear_screen_buffers()
        rlgl.load_draw_cube()
        face += 1

    rlgl.disable_shader()
    rlgl.disable_texture()
    rlgl.disable_framebuffer()
    rlgl.unload_framebuffer(framebuffer)
    rlgl.viewport(0, 0, rlgl.get_framebuffer_width(), rlgl.get_framebuffer_height())
    rlgl.enable_backface_culling()

    cubemap.width = size
    cubemap.height = size
    cubemap.mipmaps = 1
    cubemap.format = format
    return cubemap


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - skybox rendering")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 1.0, y = 1.0, z = 1.0),
        target = rl.Vector3(x = 4.0, y = 1.0, z = 4.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    var skybox = rl.load_model_from_mesh(rl.gen_mesh_cube(1.0, 1.0, 1.0))
    defer rl.unload_model(skybox)

    let use_hdr = false

    let skybox_vertex_shader = rl.text_format("shaders/glsl%i/skybox.vs", GLSL_VERSION)
    let skybox_fragment_shader = rl.text_format("shaders/glsl%i/skybox.fs", GLSL_VERSION)
    unsafe: skybox.materials[0].shader = rl.load_shader(skybox_vertex_shader, skybox_fragment_shader)
    defer rl.unload_shader(unsafe: skybox.materials[0].shader)

    let environment_map_loc = rl.get_shader_location(unsafe: skybox.materials[0].shader, "environmentMap")
    let do_gamma_loc = rl.get_shader_location(unsafe: skybox.materials[0].shader, "doGamma")
    let vflipped_loc = rl.get_shader_location(unsafe: skybox.materials[0].shader, "vflipped")
    let environment_map_slot = int<-rl.MaterialMapIndex.MATERIAL_MAP_CUBEMAP
    let gamma_value = if use_hdr: 1 else: 0
    rl.set_shader_value(
        unsafe: skybox.materials[0].shader,
        environment_map_loc,
        environment_map_slot,
        int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT
    )
    rl.set_shader_value(
        unsafe: skybox.materials[0].shader,
        do_gamma_loc,
        gamma_value,
        int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT
    )
    rl.set_shader_value(
        unsafe: skybox.materials[0].shader,
        vflipped_loc,
        gamma_value,
        int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT
    )

    let cubemap_vertex_shader = rl.text_format("shaders/glsl%i/cubemap.vs", GLSL_VERSION)
    let cubemap_fragment_shader = rl.text_format("shaders/glsl%i/cubemap.fs", GLSL_VERSION)
    let cubemap_shader = rl.load_shader(cubemap_vertex_shader, cubemap_fragment_shader)
    defer rl.unload_shader(cubemap_shader)
    let equirectangular_map_loc = rl.get_shader_location(cubemap_shader, "equirectangularMap")
    rl.set_shader_value(cubemap_shader, equirectangular_map_loc, 0, int<-rl.ShaderUniformDataType.SHADER_UNIFORM_INT)

    var skybox_file_name = "skybox.png"
    if use_hdr:
        skybox_file_name = "dresden_square_2k.hdr"
        let panorama = rl.load_texture(skybox_file_name)
        defer rl.unload_texture(panorama)
        unsafe: skybox.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_CUBEMAP].texture = gen_texture_cubemap(
            cubemap_shader,
            panorama,
            1024,
            int<-rl.PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8
        )
    else:
        let image = rl.load_image(skybox_file_name)
        defer rl.unload_image(image)
        unsafe: skybox.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_CUBEMAP].texture = rl.load_texture_cubemap(
            image,
            int<-rl.CubemapLayout.CUBEMAP_LAYOUT_AUTO_DETECT
        )

    defer rl.unload_texture(unsafe: skybox.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_CUBEMAP].texture)

    rl.disable_cursor()
    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_FIRST_PERSON)

        if rl.is_file_dropped():
            let dropped_files = rl.load_dropped_files()
            defer rl.unload_dropped_files(dropped_files)

            if dropped_files.count == 1u:
                let dropped_path = unsafe: text.chars_as_str(read(dropped_files.paths))
                if rl.is_file_extension(dropped_path, ".png;.jpg;.hdr;.bmp;.tga"):
                    rl.unload_texture(unsafe: skybox.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_CUBEMAP].texture)

                    if use_hdr:
                        let panorama = rl.load_texture(dropped_path)
                        defer rl.unload_texture(panorama)
                        unsafe: skybox.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_CUBEMAP].texture = gen_texture_cubemap(
                            cubemap_shader,
                            panorama,
                            1024,
                            int<-rl.PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8
                        )
                    else:
                        let image = rl.load_image(dropped_path)
                        defer rl.unload_image(image)
                        unsafe: skybox.materials[0].maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_CUBEMAP].texture = rl.load_texture_cubemap(
                            image,
                            int<-rl.CubemapLayout.CUBEMAP_LAYOUT_AUTO_DETECT
                        )

                    skybox_file_name = dropped_path

        let current_file_name = text.cstr_as_str(rl.get_file_name(skybox_file_name))
        var skybox_label = rl.text_format(": %s", current_file_name)
        if use_hdr:
            skybox_label = rl.text_format("Panorama image from hdrihaven.com: %s", current_file_name)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rlgl.disable_backface_culling()
        rlgl.disable_depth_mask()
        rl.draw_model(skybox, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 1.0, rl.WHITE)
        rlgl.enable_backface_culling()
        rlgl.enable_depth_mask()
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        rl.draw_text(skybox_label, 10, rl.get_screen_height() - 20, 10, rl.BLACK)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
