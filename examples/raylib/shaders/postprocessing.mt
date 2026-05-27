import std.raylib as rl
import std.raylib.runtime as rl_runtime


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const GLSL_VERSION: int = 330
const MAX_POSTPRO_SHADERS: int = 12
const FX_GRAYSCALE: int = 0
const FX_POSTERIZATION: int = 1
const FX_DREAM_VISION: int = 2
const FX_PIXELIZER: int = 3
const FX_CROSS_HATCHING: int = 4
const FX_CROSS_STITCHING: int = 5
const FX_PREDATOR_VIEW: int = 6
const FX_SCANLINES: int = 7
const FX_FISHEYE: int = 8
const FX_SOBEL: int = 9
const FX_BLOOM: int = 10
const FX_BLUR: int = 11

const POSTPRO_SHADER_TEXT: array[str, MAX_POSTPRO_SHADERS] = array[str, MAX_POSTPRO_SHADERS](
    "GRAYSCALE",
    "POSTERIZATION",
    "DREAM_VISION",
    "PIXELIZER",
    "CROSS_HATCHING",
    "CROSS_STITCHING",
    "PREDATOR_VIEW",
    "SCANLINES",
    "FISHEYE",
    "SOBEL",
    "BLOOM",
    "BLUR",
)


function main() -> int:
    rl.set_config_flags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [shaders] example - postprocessing")
    defer rl.close_window()

    if not rl_runtime.enter_asset_directory("../resources"):
        fatal("could not enter examples/raylib/resources")

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 2.0, y = 3.0, z = 2.0),
        target = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var model = rl.load_model("models/church.obj")
    defer rl.unload_model(model)
    let texture = rl.load_texture("models/church_diffuse.png")
    defer rl.unload_texture(texture)
    rl.set_material_texture(model.materials, int<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    var shaders = zero[array[rl.Shader, MAX_POSTPRO_SHADERS]]
    shaders[FX_GRAYSCALE] = rl.load_shader(null, rl.text_format("shaders/glsl%i/grayscale.fs", GLSL_VERSION))
    shaders[FX_POSTERIZATION] = rl.load_shader(null, rl.text_format("shaders/glsl%i/posterization.fs", GLSL_VERSION))
    shaders[FX_DREAM_VISION] = rl.load_shader(null, rl.text_format("shaders/glsl%i/dream_vision.fs", GLSL_VERSION))
    shaders[FX_PIXELIZER] = rl.load_shader(null, rl.text_format("shaders/glsl%i/pixelizer.fs", GLSL_VERSION))
    shaders[FX_CROSS_HATCHING] = rl.load_shader(null, rl.text_format("shaders/glsl%i/cross_hatching.fs", GLSL_VERSION))
    shaders[FX_CROSS_STITCHING] = rl.load_shader(null, rl.text_format("shaders/glsl%i/cross_stitching.fs", GLSL_VERSION))
    shaders[FX_PREDATOR_VIEW] = rl.load_shader(null, rl.text_format("shaders/glsl%i/predator.fs", GLSL_VERSION))
    shaders[FX_SCANLINES] = rl.load_shader(null, rl.text_format("shaders/glsl%i/scanlines.fs", GLSL_VERSION))
    shaders[FX_FISHEYE] = rl.load_shader(null, rl.text_format("shaders/glsl%i/fisheye.fs", GLSL_VERSION))
    shaders[FX_SOBEL] = rl.load_shader(null, rl.text_format("shaders/glsl%i/sobel.fs", GLSL_VERSION))
    shaders[FX_BLOOM] = rl.load_shader(null, rl.text_format("shaders/glsl%i/bloom.fs", GLSL_VERSION))
    shaders[FX_BLUR] = rl.load_shader(null, rl.text_format("shaders/glsl%i/blur.fs", GLSL_VERSION))
    defer:
        var shader_index = 0
        while shader_index < MAX_POSTPRO_SHADERS:
            rl.unload_shader(shaders[shader_index])
            shader_index += 1

    let target = rl.load_render_texture(SCREEN_WIDTH, SCREEN_HEIGHT)
    defer rl.unload_render_texture(target)

    var current_shader = FX_GRAYSCALE
    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_ORBITAL)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_RIGHT):
            current_shader += 1
        else if rl.is_key_pressed(rl.KeyboardKey.KEY_LEFT):
            current_shader -= 1

        if current_shader >= MAX_POSTPRO_SHADERS:
            current_shader = 0
        else if current_shader < 0:
            current_shader = MAX_POSTPRO_SHADERS - 1

        rl.begin_texture_mode(target)
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_model(model, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 0.1, rl.WHITE)
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()
        rl.end_texture_mode()

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_shader_mode(shaders[current_shader])
        rl.draw_texture_rec(
            target.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = float<-target.texture.width, height = -(float<-target.texture.height)),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE,
        )
        rl.end_shader_mode()

        rl.draw_rectangle(0, 9, 580, 30, rl.fade(rl.LIGHTGRAY, 0.7))
        rl.draw_text("(c) Church 3D model by Alberto Cano", SCREEN_WIDTH - 200, SCREEN_HEIGHT - 20, 10, rl.GRAY)
        rl.draw_text("CURRENT POSTPRO SHADER:", 10, 15, 20, rl.BLACK)
        rl.draw_text(POSTPRO_SHADER_TEXT[current_shader], 330, 15, 20, rl.RED)
        rl.draw_text("< >", 540, 10, 30, rl.DARKBLUE)
        rl.draw_fps(700, 15)
        rl.end_drawing()

    return 0
