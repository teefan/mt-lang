module examples.raylib.models.models_skybox_rendering

import std.c.raylib as rl
import std.c.rlgl as rlgl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const glsl_version: i32 = 330
const skybox_texture_path: cstr = c"../resources/skybox.png"
const skybox_hdr_path: cstr = c"../resources/dresden_square_2k.hdr"
const skybox_shader_vertex_path_format: cstr = c"../resources/shaders/glsl%i/skybox.vs"
const skybox_shader_fragment_path_format: cstr = c"../resources/shaders/glsl%i/skybox.fs"
const cubemap_shader_vertex_path_format: cstr = c"../resources/shaders/glsl%i/cubemap.vs"
const cubemap_shader_fragment_path_format: cstr = c"../resources/shaders/glsl%i/cubemap.fs"
const drop_extensions: cstr = c".png;.jpg;.hdr;.bmp;.tga"
const hdr_caption_format: cstr = c"Panorama image from hdrihaven.com: %s"
const caption_format: cstr = c": %s"
const environment_map_text: cstr = c"environmentMap"
const equirectangular_map_text: cstr = c"equirectangularMap"
const do_gamma_text: cstr = c"doGamma"
const vflipped_text: cstr = c"vflipped"
const window_title: cstr = c"raylib [models] example - skybox rendering"

def chars_to_cstr(text: ptr[char]) -> cstr:
    unsafe:
        return cstr<-text

def text_buffer_ptr(text: ref[array[char, 256]]) -> ptr[char]:
    return raw(addr(value(text)[0]))

def text_buffer_cstr(text: ref[array[char, 256]]) -> cstr:
    return chars_to_cstr(text_buffer_ptr(text))

def shader_location(shader: rl.Shader, location_index: i32) -> i32:
    unsafe:
        return deref(shader.locs + location_index)

def file_path_list_path(files: rl.FilePathList, index: i32) -> cstr:
    unsafe:
        return cstr<-deref(files.paths + usize<-index)

def rlgl_matrix(mat: rl.Matrix) -> rlgl.Matrix:
    return rlgl.Matrix(
        m0 = mat.m0,
        m4 = mat.m4,
        m8 = mat.m8,
        m12 = mat.m12,
        m1 = mat.m1,
        m5 = mat.m5,
        m9 = mat.m9,
        m13 = mat.m13,
        m2 = mat.m2,
        m6 = mat.m6,
        m10 = mat.m10,
        m14 = mat.m14,
        m3 = mat.m3,
        m7 = mat.m7,
        m11 = mat.m11,
        m15 = mat.m15,
    )

def set_shader_int(shader: rl.Shader, uniform_name: cstr, value: i32) -> void:
    var raw_value = zero[array[i32, 1]]()
    raw_value[0] = value
    rl.SetShaderValue(
        shader,
        rl.GetShaderLocation(shader, uniform_name),
        raw(addr(raw_value[0])),
        rl.ShaderUniformDataType.SHADER_UNIFORM_INT,
    )

def set_skybox_shader(model: ptr[rl.Model], shader: rl.Shader) -> void:
    unsafe:
        model.materials[0].shader = shader

def set_skybox_cubemap(model: ptr[rl.Model], texture: rl.TextureCubemap) -> void:
    unsafe:
        model.materials[0].maps[i32<-rl.MaterialMapIndex.MATERIAL_MAP_CUBEMAP].texture = texture

def skybox_cubemap(model: rl.Model) -> rl.TextureCubemap:
    unsafe:
        return model.materials[0].maps[i32<-rl.MaterialMapIndex.MATERIAL_MAP_CUBEMAP].texture

def gen_texture_cubemap(shader: rl.Shader, panorama: rl.Texture2D, size: i32, format: i32) -> rl.TextureCubemap:
    var cubemap = zero[rl.TextureCubemap]()

    rlgl.rlDisableBackfaceCulling()

    let rbo = rlgl.rlLoadTextureDepth(size, size, true)
    cubemap.id = rlgl.rlLoadTextureCubemap(null, size, format, 1)

    let fbo = rlgl.rlLoadFramebuffer()
    rlgl.rlFramebufferAttach(
        fbo,
        rbo,
        i32<-rlgl.rlFramebufferAttachType.RL_ATTACHMENT_DEPTH,
        i32<-rlgl.rlFramebufferAttachTextureType.RL_ATTACHMENT_RENDERBUFFER,
        0,
    )
    rlgl.rlFramebufferAttach(
        fbo,
        cubemap.id,
        i32<-rlgl.rlFramebufferAttachType.RL_ATTACHMENT_COLOR_CHANNEL0,
        i32<-rlgl.rlFramebufferAttachTextureType.RL_ATTACHMENT_CUBEMAP_POSITIVE_X,
        0,
    )

    rlgl.rlEnableShader(shader.id)

    let projection = rm.Matrix.perspective(
        90.0 * rm.deg2rad,
        1.0,
        f32<-rlgl.rlGetCullDistanceNear(),
        f32<-rlgl.rlGetCullDistanceFar(),
    )
    rlgl.rlSetUniformMatrix(shader_location(shader, i32<-rl.ShaderLocationIndex.SHADER_LOC_MATRIX_PROJECTION), rlgl_matrix(projection))

    var fbo_views = zero[array[rl.Matrix, 6]]()
    fbo_views[0] = rm.Matrix.look_at(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector3(x = 1.0, y = 0.0, z = 0.0), rl.Vector3(x = 0.0, y = -1.0, z = 0.0))
    fbo_views[1] = rm.Matrix.look_at(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector3(x = -1.0, y = 0.0, z = 0.0), rl.Vector3(x = 0.0, y = -1.0, z = 0.0))
    fbo_views[2] = rm.Matrix.look_at(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector3(x = 0.0, y = 1.0, z = 0.0), rl.Vector3(x = 0.0, y = 0.0, z = 1.0))
    fbo_views[3] = rm.Matrix.look_at(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector3(x = 0.0, y = -1.0, z = 0.0), rl.Vector3(x = 0.0, y = 0.0, z = -1.0))
    fbo_views[4] = rm.Matrix.look_at(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector3(x = 0.0, y = 0.0, z = 1.0), rl.Vector3(x = 0.0, y = -1.0, z = 0.0))
    fbo_views[5] = rm.Matrix.look_at(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector3(x = 0.0, y = 0.0, z = -1.0), rl.Vector3(x = 0.0, y = -1.0, z = 0.0))

    rlgl.rlViewport(0, 0, size, size)
    rlgl.rlActiveTextureSlot(0)
    rlgl.rlEnableTexture(panorama.id)

    for index in range(0, 6):
        rlgl.rlSetUniformMatrix(shader_location(shader, i32<-rl.ShaderLocationIndex.SHADER_LOC_MATRIX_VIEW), rlgl_matrix(fbo_views[index]))
        rlgl.rlFramebufferAttach(
            fbo,
            cubemap.id,
            i32<-rlgl.rlFramebufferAttachType.RL_ATTACHMENT_COLOR_CHANNEL0,
            i32<-rlgl.rlFramebufferAttachTextureType.RL_ATTACHMENT_CUBEMAP_POSITIVE_X + index,
            0,
        )
        rlgl.rlEnableFramebuffer(fbo)
        rlgl.rlClearScreenBuffers()
        rlgl.rlLoadDrawCube()

    rlgl.rlDisableShader()
    rlgl.rlDisableTexture()
    rlgl.rlDisableFramebuffer()
    rlgl.rlUnloadFramebuffer(fbo)

    rlgl.rlViewport(0, 0, rlgl.rlGetFramebufferWidth(), rlgl.rlGetFramebufferHeight())
    rlgl.rlEnableBackfaceCulling()

    cubemap.width = size
    cubemap.height = size
    cubemap.mipmaps = 1
    cubemap.format = format

    return cubemap

def load_skybox_texture(skybox: ptr[rl.Model], cubemap_shader: rl.Shader, use_hdr: bool, skybox_file_name: ref[array[char, 256]], file_path: cstr) -> void:
    rl.TextCopy(text_buffer_ptr(skybox_file_name), file_path)

    if use_hdr:
        let panorama = rl.LoadTexture(file_path)
        set_skybox_cubemap(
            skybox,
            gen_texture_cubemap(
                cubemap_shader,
                panorama,
                1024,
                i32<-rl.PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
            ),
        )
        rl.UnloadTexture(panorama)
    else:
        let image = rl.LoadImage(file_path)
        set_skybox_cubemap(skybox, rl.LoadTextureCubemap(image, i32<-rl.CubemapLayout.CUBEMAP_LAYOUT_AUTO_DETECT))
        rl.UnloadImage(image)

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 1.0, y = 1.0, z = 1.0),
        target = rl.Vector3(x = 4.0, y = 1.0, z = 4.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let cube = rl.GenMeshCube(1.0, 1.0, 1.0)
    var skybox = rl.LoadModelFromMesh(cube)
    defer rl.UnloadModel(skybox)

    let use_hdr = false

    let skybox_shader = rl.LoadShader(
        rl.TextFormat(skybox_shader_vertex_path_format, glsl_version),
        rl.TextFormat(skybox_shader_fragment_path_format, glsl_version),
    )
    defer rl.UnloadShader(skybox_shader)
    set_skybox_shader(raw(addr(skybox)), skybox_shader)

    set_shader_int(skybox_shader, environment_map_text, i32<-rl.MaterialMapIndex.MATERIAL_MAP_CUBEMAP)
    set_shader_int(skybox_shader, do_gamma_text, if use_hdr then 1 else 0)
    set_shader_int(skybox_shader, vflipped_text, if use_hdr then 1 else 0)

    let cubemap_shader = rl.LoadShader(
        rl.TextFormat(cubemap_shader_vertex_path_format, glsl_version),
        rl.TextFormat(cubemap_shader_fragment_path_format, glsl_version),
    )
    defer rl.UnloadShader(cubemap_shader)
    set_shader_int(cubemap_shader, equirectangular_map_text, 0)

    var skybox_file_name = zero[array[char, 256]]()
    load_skybox_texture(raw(addr(skybox)), cubemap_shader, use_hdr, addr(skybox_file_name), if use_hdr then skybox_hdr_path else skybox_texture_path)

    rl.DisableCursor()
    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(raw(addr(camera)), rl.CameraMode.CAMERA_FIRST_PERSON)

        if rl.IsFileDropped():
            let dropped_files = rl.LoadDroppedFiles()

            if dropped_files.count == 1:
                let dropped_path = file_path_list_path(dropped_files, 0)
                if rl.IsFileExtension(dropped_path, drop_extensions):
                    rl.UnloadTexture(skybox_cubemap(skybox))
                    load_skybox_texture(raw(addr(skybox)), cubemap_shader, use_hdr, addr(skybox_file_name), dropped_path)

            rl.UnloadDroppedFiles(dropped_files)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)
        rlgl.rlDisableBackfaceCulling()
        rlgl.rlDisableDepthMask()
        rl.DrawModel(skybox, rl.Vector3(x = 0.0, y = 0.0, z = 0.0), 1.0, rl.WHITE)
        rlgl.rlEnableBackfaceCulling()
        rlgl.rlEnableDepthMask()
        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()

        if use_hdr:
            rl.DrawText(rl.TextFormat(hdr_caption_format, rl.GetFileName(text_buffer_cstr(addr(skybox_file_name)))), 10, rl.GetScreenHeight() - 20, 10, rl.BLACK)
        else:
            rl.DrawText(rl.TextFormat(caption_format, rl.GetFileName(text_buffer_cstr(addr(skybox_file_name)))), 10, rl.GetScreenHeight() - 20, 10, rl.BLACK)

        rl.DrawFPS(10, 10)

    return 0
