import std.c.raylib as c
import std.c.rlgl as c_rlgl
import std.raylib as rl
import std.raylib.runtime as rl_runtime
import std.rlgl as rlgl
import std.raymath as rm

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330
const MAP_SIZE: int = 16
const LIGHTMAP_ATTRIBUTE_LOCATION: uint = 5


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - lightmap rendering")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 4.0, y = 6.0, z = 8.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    var mesh = rl.gen_mesh_plane(float<-MAP_SIZE, float<-MAP_SIZE, 1, 1)
    defer rl.unload_mesh(mesh)

    let raw_texcoords2 = c.MemAlloc(uint<-(mesh.vertexCount * 2 * int<-size_of(float))) else:
        fatal("could not allocate texcoords2 for lightmap mesh")
    let texcoords2 = unsafe: ptr[float]<-raw_texcoords2
    unsafe: mesh.texcoords2 = texcoords2
    unsafe:
        texcoords2[0] = 0.0
        texcoords2[1] = 0.0
        texcoords2[2] = 1.0
        texcoords2[3] = 0.0
        texcoords2[4] = 0.0
        texcoords2[5] = 1.0
        texcoords2[6] = 1.0
        texcoords2[7] = 1.0

    unsafe:
        mesh.vboId[int<-rl.ShaderLocationIndex.SHADER_LOC_VERTEX_TEXCOORD02] = rlgl.load_vertex_buffer(
            texcoords2,
            mesh.vertexCount * 2 * int<-size_of(float),
            false
        )
    rlgl.enable_vertex_array(mesh.vaoId)
    rlgl.set_vertex_attribute(LIGHTMAP_ATTRIBUTE_LOCATION, 2, c_rlgl.RL_FLOAT, false, 0, 0)
    rlgl.enable_vertex_attribute(LIGHTMAP_ATTRIBUTE_LOCATION)
    rlgl.disable_vertex_array()

    let shader = rl.load_shader(
        rl.text_format("shaders/glsl%i/lightmap.vs", GLSL_VERSION),
        rl.text_format("shaders/glsl%i/lightmap.fs", GLSL_VERSION)
    )
    defer rl.unload_shader(shader)

    var texture = rl.load_texture("cubicmap_atlas.png")
    defer rl.unload_texture(texture)
    let light = rl.load_texture("spark_flame.png")
    defer rl.unload_texture(light)

    rl.gen_texture_mipmaps(texture)
    rl.set_texture_filter(texture, int<-rl.TextureFilter.TEXTURE_FILTER_TRILINEAR)

    let lightmap = rl.load_render_texture(MAP_SIZE, MAP_SIZE)
    defer rl.unload_render_texture(lightmap)
    var lightmap_texture = lightmap.texture

    var material = rl.load_material_default()
    unsafe: material.shader = shader
    unsafe: material.maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO].texture = texture
    unsafe: material.maps[int<-rl.MaterialMapIndex.MATERIAL_MAP_METALNESS].texture = lightmap_texture

    rl.begin_texture_mode(lightmap)
    rl.clear_background(rl.BLACK)
    rl.begin_blend_mode(int<-rl.BlendMode.BLEND_ADDITIVE)
    rl.draw_texture_pro(
        light,
        rl.Rectangle(x = 0.0, y = 0.0, width = float<-light.width, height = float<-light.height),
        rl.Rectangle(x = 0.0, y = 0.0, width = 2.0 * float<-MAP_SIZE, height = 2.0 * float<-MAP_SIZE),
        rl.Vector2(x = float<-MAP_SIZE, y = float<-MAP_SIZE),
        0.0,
        rl.RED
    )
    rl.draw_texture_pro(
        light,
        rl.Rectangle(x = 0.0, y = 0.0, width = float<-light.width, height = float<-light.height),
        rl.Rectangle(
            x = float<-MAP_SIZE * 0.8,
            y = float<-MAP_SIZE / 2.0,
            width = 2.0 * float<-MAP_SIZE,
            height = 2.0 * float<-MAP_SIZE
        ),
        rl.Vector2(x = float<-MAP_SIZE, y = float<-MAP_SIZE),
        0.0,
        rl.BLUE
    )
    rl.draw_texture_pro(
        light,
        rl.Rectangle(x = 0.0, y = 0.0, width = float<-light.width, height = float<-light.height),
        rl.Rectangle(
            x = float<-MAP_SIZE * 0.8,
            y = float<-MAP_SIZE * 0.8,
            width = float<-MAP_SIZE,
            height = float<-MAP_SIZE
        ),
        rl.Vector2(x = float<-MAP_SIZE / 2.0, y = float<-MAP_SIZE / 2.0),
        0.0,
        rl.GREEN
    )
    rl.end_blend_mode()
    rl.end_texture_mode()

    rl.gen_texture_mipmaps(lightmap_texture)
    rl.set_texture_filter(lightmap_texture, int<-rl.TextureFilter.TEXTURE_FILTER_TRILINEAR)

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_mesh(mesh, material, rm.matrix_identity())
        rl.end_mode_3d()

        rl.draw_texture_pro(
            lightmap_texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = -(float<-MAP_SIZE), height = -(float<-MAP_SIZE)),
            rl.Rectangle(
                x = float<-rl.get_render_width() - float<-(MAP_SIZE * 8) - 10.0,
                y = 10.0,
                width = float<-(MAP_SIZE * 8),
                height = float<-(MAP_SIZE * 8)
            ),
            rl.Vector2(x = 0.0, y = 0.0),
            0.0,
            rl.WHITE
        )
        rl.draw_text(
            rl.text_format("LIGHTMAP: %ix%i pixels", MAP_SIZE, MAP_SIZE),
            rl.get_render_width() - 130,
            20 + MAP_SIZE * 8,
            10,
            rl.GREEN
        )
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
