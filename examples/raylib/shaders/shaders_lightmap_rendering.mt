module examples.raylib.shaders.shaders_lightmap_rendering

import std.c.raylib as rl
import std.c.rlgl as rlgl
import std.raylib.math as rm

const glsl_version: i32 = 330
const map_size: i32 = 16
const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [shaders] example - lightmap rendering"
const vertex_shader_path_format: cstr = c"../resources/shaders/glsl%i/lightmap.vs"
const fragment_shader_path_format: cstr = c"../resources/shaders/glsl%i/lightmap.fs"
const texture_path: cstr = c"../resources/cubicmap_atlas.png"
const light_path: cstr = c"../resources/spark_flame.png"
const lightmap_label_format: cstr = c"LIGHTMAP: %ix%i pixels"

def main() -> i32:
    rl.SetConfigFlags(rl.ConfigFlags.FLAG_MSAA_4X_HINT)
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 4.0, y = 6.0, z = 8.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var mesh = rl.GenMeshPlane(f32<-map_size, f32<-map_size, 1, 1)

    unsafe:
        mesh.texcoords2 = ptr[f32]<-rl.MemAlloc(u32<-(mesh.vertexCount * 2) * u32<-sizeof(f32))
        mesh.texcoords2[0] = 0.0
        mesh.texcoords2[1] = 0.0
        mesh.texcoords2[2] = 1.0
        mesh.texcoords2[3] = 0.0
        mesh.texcoords2[4] = 0.0
        mesh.texcoords2[5] = 1.0
        mesh.texcoords2[6] = 1.0
        mesh.texcoords2[7] = 1.0

        mesh.vboId[i32<-rl.ShaderLocationIndex.SHADER_LOC_VERTEX_TEXCOORD02] = rlgl.rlLoadVertexBuffer(ptr[void]<-mesh.texcoords2, mesh.vertexCount * 2 * i32<-sizeof(f32), false)
        rlgl.rlEnableVertexArray(mesh.vaoId)
        rlgl.rlSetVertexAttribute(5, 2, rlgl.RL_FLOAT, false, 0, 0)
        rlgl.rlEnableVertexAttribute(5)
        rlgl.rlDisableVertexArray()

    let shader = rl.LoadShader(
        rl.TextFormat(vertex_shader_path_format, glsl_version),
        rl.TextFormat(fragment_shader_path_format, glsl_version),
    )
    defer rl.UnloadShader(shader)

    var texture = rl.LoadTexture(texture_path)
    defer rl.UnloadTexture(texture)
    let light = rl.LoadTexture(light_path)
    defer rl.UnloadTexture(light)

    rl.GenTextureMipmaps(ptr_of(ref_of(texture)))
    rl.SetTextureFilter(texture, rl.TextureFilter.TEXTURE_FILTER_TRILINEAR)

    var lightmap = rl.LoadRenderTexture(map_size, map_size)
    defer rl.UnloadRenderTexture(lightmap)

    var material = rl.LoadMaterialDefault()
    material.shader = shader
    unsafe:
        material.maps[i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO].texture = texture
        material.maps[i32<-rl.MaterialMapIndex.MATERIAL_MAP_METALNESS].texture = lightmap.texture

    rl.BeginTextureMode(lightmap)
    rl.ClearBackground(rl.BLACK)
    rl.BeginBlendMode(rl.BlendMode.BLEND_ADDITIVE)
    rl.DrawTexturePro(
        light,
        rl.Rectangle(x = 0.0, y = 0.0, width = f32<-light.width, height = f32<-light.height),
        rl.Rectangle(x = 0.0, y = 0.0, width = f32<-(2 * map_size), height = f32<-(2 * map_size)),
        rl.Vector2(x = f32<-map_size, y = f32<-map_size),
        0.0,
        rl.RED,
    )
    rl.DrawTexturePro(
        light,
        rl.Rectangle(x = 0.0, y = 0.0, width = f32<-light.width, height = f32<-light.height),
        rl.Rectangle(x = f32<-map_size * 0.8, y = f32<-map_size / 2.0, width = f32<-(2 * map_size), height = f32<-(2 * map_size)),
        rl.Vector2(x = f32<-map_size, y = f32<-map_size),
        0.0,
        rl.BLUE,
    )
    rl.DrawTexturePro(
        light,
        rl.Rectangle(x = 0.0, y = 0.0, width = f32<-light.width, height = f32<-light.height),
        rl.Rectangle(x = f32<-map_size * 0.8, y = f32<-map_size * 0.8, width = f32<-map_size, height = f32<-map_size),
        rl.Vector2(x = f32<-map_size / 2.0, y = f32<-map_size / 2.0),
        0.0,
        rl.GREEN,
    )
    rl.EndBlendMode()
    rl.EndTextureMode()

    rl.GenTextureMipmaps(ptr_of(ref_of(lightmap.texture)))
    rl.SetTextureFilter(lightmap.texture, rl.TextureFilter.TEXTURE_FILTER_TRILINEAR)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(ref_of(camera)), rl.CameraMode.CAMERA_ORBITAL)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode3D(camera)
        rl.DrawMesh(mesh, material, rm.Matrix.identity())
        rl.EndMode3D()

        rl.DrawTexturePro(
            lightmap.texture,
            rl.Rectangle(x = 0.0, y = 0.0, width = -f32<-map_size, height = -f32<-map_size),
            rl.Rectangle(x = f32<-(rl.GetRenderWidth() - map_size * 8 - 10), y = 10.0, width = f32<-(map_size * 8), height = f32<-(map_size * 8)),
            rl.Vector2(x = 0.0, y = 0.0),
            0.0,
            rl.WHITE,
        )
        rl.DrawText(rl.TextFormat(lightmap_label_format, map_size, map_size), rl.GetRenderWidth() - 130, 20 + map_size * 8, 10, rl.GREEN)
        rl.DrawFPS(10, 10)

    rl.UnloadMaterial(material)
    rl.UnloadMesh(mesh)
    return 0
