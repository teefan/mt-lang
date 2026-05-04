module examples.raylib.shaders.shaders_postprocessing

import std.c.raylib as rl

const max_postpro_shaders: i32 = 12
const fx_grayscale: i32 = 0
const fx_posterization: i32 = 1
const fx_dream_vision: i32 = 2
const fx_pixelizer: i32 = 3
const fx_cross_hatching: i32 = 4
const fx_cross_stitching: i32 = 5
const fx_predator_view: i32 = 6
const fx_scanlines: i32 = 7
const fx_fisheye: i32 = 8
const fx_sobel: i32 = 9
const fx_bloom: i32 = 10
const fx_blur: i32 = 11
const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const model_path: cstr = c"../resources/models/church.obj"
const texture_path: cstr = c"../resources/models/church_diffuse.png"
const grayscale_shader_path: cstr = c"../resources/shaders/glsl%i/grayscale.fs"
const posterization_shader_path: cstr = c"../resources/shaders/glsl%i/posterization.fs"
const dream_vision_shader_path: cstr = c"../resources/shaders/glsl%i/dream_vision.fs"
const pixelizer_shader_path: cstr = c"../resources/shaders/glsl%i/pixelizer.fs"
const cross_hatching_shader_path: cstr = c"../resources/shaders/glsl%i/cross_hatching.fs"
const cross_stitching_shader_path: cstr = c"../resources/shaders/glsl%i/cross_stitching.fs"
const predator_shader_path: cstr = c"../resources/shaders/glsl%i/predator.fs"
const scanlines_shader_path: cstr = c"../resources/shaders/glsl%i/scanlines.fs"
const fisheye_shader_path: cstr = c"../resources/shaders/glsl%i/fisheye.fs"
const sobel_shader_path: cstr = c"../resources/shaders/glsl%i/sobel.fs"
const bloom_shader_path: cstr = c"../resources/shaders/glsl%i/bloom.fs"
const blur_shader_path: cstr = c"../resources/shaders/glsl%i/blur.fs"
const credit_text: cstr = c"(c) Church 3D model by Alberto Cano"
const title_text: cstr = c"CURRENT POSTPRO SHADER:"
const switch_text: cstr = c"< >"
const window_title: cstr = c"raylib [shaders] example - postprocessing"


def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)

    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 2.0, y = 3.0, z = 2.0),
        target = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var model = rl.LoadModel(model_path)
    defer rl.UnloadModel(model)

    let texture = rl.LoadTexture(texture_path)
    defer rl.UnloadTexture(texture)
    rl.SetMaterialTexture(model.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    let shader_names = array[cstr, max_postpro_shaders](
        c"GRAYSCALE",
        c"POSTERIZATION",
        c"DREAM_VISION",
        c"PIXELIZER",
        c"CROSS_HATCHING",
        c"CROSS_STITCHING",
        c"PREDATOR_VIEW",
        c"SCANLINES",
        c"FISHEYE",
        c"SOBEL",
        c"BLOOM",
        c"BLUR",
    )

    var shaders = zero[array[rl.Shader, max_postpro_shaders]]()
    shaders[fx_grayscale] = rl.LoadShader(zero[cstr?](), rl.TextFormat(grayscale_shader_path, glsl_version))
    shaders[fx_posterization] = rl.LoadShader(zero[cstr?](), rl.TextFormat(posterization_shader_path, glsl_version))
    shaders[fx_dream_vision] = rl.LoadShader(zero[cstr?](), rl.TextFormat(dream_vision_shader_path, glsl_version))
    shaders[fx_pixelizer] = rl.LoadShader(zero[cstr?](), rl.TextFormat(pixelizer_shader_path, glsl_version))
    shaders[fx_cross_hatching] = rl.LoadShader(zero[cstr?](), rl.TextFormat(cross_hatching_shader_path, glsl_version))
    shaders[fx_cross_stitching] = rl.LoadShader(zero[cstr?](), rl.TextFormat(cross_stitching_shader_path, glsl_version))
    shaders[fx_predator_view] = rl.LoadShader(zero[cstr?](), rl.TextFormat(predator_shader_path, glsl_version))
    shaders[fx_scanlines] = rl.LoadShader(zero[cstr?](), rl.TextFormat(scanlines_shader_path, glsl_version))
    shaders[fx_fisheye] = rl.LoadShader(zero[cstr?](), rl.TextFormat(fisheye_shader_path, glsl_version))
    shaders[fx_sobel] = rl.LoadShader(zero[cstr?](), rl.TextFormat(sobel_shader_path, glsl_version))
    shaders[fx_bloom] = rl.LoadShader(zero[cstr?](), rl.TextFormat(bloom_shader_path, glsl_version))
    shaders[fx_blur] = rl.LoadShader(zero[cstr?](), rl.TextFormat(blur_shader_path, glsl_version))

    defer:
        for shader_index in 0..max_postpro_shaders:
            rl.UnloadShader(shaders[shader_index])

    var current_shader = fx_grayscale
    let target = rl.LoadRenderTexture(screen_width, screen_height)
    defer rl.UnloadRenderTexture(target)

    let position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(ref_of(camera)), rl.CameraMode.CAMERA_ORBITAL)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_RIGHT):
            current_shader += 1
        elif rl.IsKeyPressed(rl.KeyboardKey.KEY_LEFT):
            current_shader -= 1

        if current_shader >= max_postpro_shaders:
            current_shader = 0
        elif current_shader < 0:
            current_shader = max_postpro_shaders - 1

        rl.BeginTextureMode(target)
        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)
        rl.DrawModel(model, position, 0.1, rl.WHITE)
        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()
        rl.EndTextureMode()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginShaderMode(shaders[current_shader])
        rl.DrawTextureRec(
            target.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = f32<-target.texture.width, height = -f32<-target.texture.height),
            rl.Vector2(x = 0.0, y = 0.0),
            rl.WHITE,
        )
        rl.EndShaderMode()

        rl.DrawRectangle(0, 9, 580, 30, rl.Fade(rl.LIGHTGRAY, 0.7))
        rl.DrawText(credit_text, screen_width - 200, screen_height - 20, 10, rl.GRAY)
        rl.DrawText(title_text, 10, 15, 20, rl.BLACK)
        rl.DrawText(shader_names[current_shader], 330, 15, 20, rl.RED)
        rl.DrawText(switch_text, 540, 10, 30, rl.DARKBLUE)
        rl.DrawFPS(700, 15)

    return 0
