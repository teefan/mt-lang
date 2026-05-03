module examples.raylib.models.models_textured_cube

import std.c.raylib as rl
import std.c.rlgl as rlgl

const screen_width: i32 = 800
const screen_height: i32 = 450
const texture_path: cstr = c"../resources/cubicmap_atlas.png"
const window_title: cstr = c"raylib [models] example - textured cube"

def draw_cube_texture(texture: rl.Texture2D, position: rl.Vector3, width: f32, height: f32, length: f32, color: rl.Color) -> void:
    let x = position.x
    let y = position.y
    let z = position.z
    let half_width = width / 2.0
    let half_height = height / 2.0
    let half_length = length / 2.0

    rlgl.rlSetTexture(texture.id)
    rlgl.rlBegin(rlgl.RL_QUADS)
    rlgl.rlColor4ub(color.r, color.g, color.b, color.a)

    rlgl.rlNormal3f(0.0, 0.0, 1.0)
    rlgl.rlTexCoord2f(0.0, 0.0)
    rlgl.rlVertex3f(x - half_width, y - half_height, z + half_length)
    rlgl.rlTexCoord2f(1.0, 0.0)
    rlgl.rlVertex3f(x + half_width, y - half_height, z + half_length)
    rlgl.rlTexCoord2f(1.0, 1.0)
    rlgl.rlVertex3f(x + half_width, y + half_height, z + half_length)
    rlgl.rlTexCoord2f(0.0, 1.0)
    rlgl.rlVertex3f(x - half_width, y + half_height, z + half_length)

    rlgl.rlNormal3f(0.0, 0.0, -1.0)
    rlgl.rlTexCoord2f(1.0, 0.0)
    rlgl.rlVertex3f(x - half_width, y - half_height, z - half_length)
    rlgl.rlTexCoord2f(1.0, 1.0)
    rlgl.rlVertex3f(x - half_width, y + half_height, z - half_length)
    rlgl.rlTexCoord2f(0.0, 1.0)
    rlgl.rlVertex3f(x + half_width, y + half_height, z - half_length)
    rlgl.rlTexCoord2f(0.0, 0.0)
    rlgl.rlVertex3f(x + half_width, y - half_height, z - half_length)

    rlgl.rlNormal3f(0.0, 1.0, 0.0)
    rlgl.rlTexCoord2f(0.0, 1.0)
    rlgl.rlVertex3f(x - half_width, y + half_height, z - half_length)
    rlgl.rlTexCoord2f(0.0, 0.0)
    rlgl.rlVertex3f(x - half_width, y + half_height, z + half_length)
    rlgl.rlTexCoord2f(1.0, 0.0)
    rlgl.rlVertex3f(x + half_width, y + half_height, z + half_length)
    rlgl.rlTexCoord2f(1.0, 1.0)
    rlgl.rlVertex3f(x + half_width, y + half_height, z - half_length)

    rlgl.rlNormal3f(0.0, -1.0, 0.0)
    rlgl.rlTexCoord2f(1.0, 1.0)
    rlgl.rlVertex3f(x - half_width, y - half_height, z - half_length)
    rlgl.rlTexCoord2f(0.0, 1.0)
    rlgl.rlVertex3f(x + half_width, y - half_height, z - half_length)
    rlgl.rlTexCoord2f(0.0, 0.0)
    rlgl.rlVertex3f(x + half_width, y - half_height, z + half_length)
    rlgl.rlTexCoord2f(1.0, 0.0)
    rlgl.rlVertex3f(x - half_width, y - half_height, z + half_length)

    rlgl.rlNormal3f(1.0, 0.0, 0.0)
    rlgl.rlTexCoord2f(1.0, 0.0)
    rlgl.rlVertex3f(x + half_width, y - half_height, z - half_length)
    rlgl.rlTexCoord2f(1.0, 1.0)
    rlgl.rlVertex3f(x + half_width, y + half_height, z - half_length)
    rlgl.rlTexCoord2f(0.0, 1.0)
    rlgl.rlVertex3f(x + half_width, y + half_height, z + half_length)
    rlgl.rlTexCoord2f(0.0, 0.0)
    rlgl.rlVertex3f(x + half_width, y - half_height, z + half_length)

    rlgl.rlNormal3f(-1.0, 0.0, 0.0)
    rlgl.rlTexCoord2f(0.0, 0.0)
    rlgl.rlVertex3f(x - half_width, y - half_height, z - half_length)
    rlgl.rlTexCoord2f(1.0, 0.0)
    rlgl.rlVertex3f(x - half_width, y - half_height, z + half_length)
    rlgl.rlTexCoord2f(1.0, 1.0)
    rlgl.rlVertex3f(x - half_width, y + half_height, z + half_length)
    rlgl.rlTexCoord2f(0.0, 1.0)
    rlgl.rlVertex3f(x - half_width, y + half_height, z - half_length)

    rlgl.rlEnd()
    rlgl.rlSetTexture(u32<-0)

def draw_cube_texture_rec(texture: rl.Texture2D, source: rl.Rectangle, position: rl.Vector3, width: f32, height: f32, length: f32, color: rl.Color) -> void:
    let x = position.x
    let y = position.y
    let z = position.z
    let tex_width = f32<-texture.width
    let tex_height = f32<-texture.height
    let half_width = width / 2.0
    let half_height = height / 2.0
    let half_length = length / 2.0

    rlgl.rlSetTexture(texture.id)
    rlgl.rlBegin(rlgl.RL_QUADS)
    rlgl.rlColor4ub(color.r, color.g, color.b, color.a)

    rlgl.rlNormal3f(0.0, 0.0, 1.0)
    rlgl.rlTexCoord2f(source.x / tex_width, (source.y + source.height) / tex_height)
    rlgl.rlVertex3f(x - half_width, y - half_height, z + half_length)
    rlgl.rlTexCoord2f((source.x + source.width) / tex_width, (source.y + source.height) / tex_height)
    rlgl.rlVertex3f(x + half_width, y - half_height, z + half_length)
    rlgl.rlTexCoord2f((source.x + source.width) / tex_width, source.y / tex_height)
    rlgl.rlVertex3f(x + half_width, y + half_height, z + half_length)
    rlgl.rlTexCoord2f(source.x / tex_width, source.y / tex_height)
    rlgl.rlVertex3f(x - half_width, y + half_height, z + half_length)

    rlgl.rlNormal3f(0.0, 0.0, -1.0)
    rlgl.rlTexCoord2f((source.x + source.width) / tex_width, (source.y + source.height) / tex_height)
    rlgl.rlVertex3f(x - half_width, y - half_height, z - half_length)
    rlgl.rlTexCoord2f((source.x + source.width) / tex_width, source.y / tex_height)
    rlgl.rlVertex3f(x - half_width, y + half_height, z - half_length)
    rlgl.rlTexCoord2f(source.x / tex_width, source.y / tex_height)
    rlgl.rlVertex3f(x + half_width, y + half_height, z - half_length)
    rlgl.rlTexCoord2f(source.x / tex_width, (source.y + source.height) / tex_height)
    rlgl.rlVertex3f(x + half_width, y - half_height, z - half_length)

    rlgl.rlNormal3f(0.0, 1.0, 0.0)
    rlgl.rlTexCoord2f(source.x / tex_width, source.y / tex_height)
    rlgl.rlVertex3f(x - half_width, y + half_height, z - half_length)
    rlgl.rlTexCoord2f(source.x / tex_width, (source.y + source.height) / tex_height)
    rlgl.rlVertex3f(x - half_width, y + half_height, z + half_length)
    rlgl.rlTexCoord2f((source.x + source.width) / tex_width, (source.y + source.height) / tex_height)
    rlgl.rlVertex3f(x + half_width, y + half_height, z + half_length)
    rlgl.rlTexCoord2f((source.x + source.width) / tex_width, source.y / tex_height)
    rlgl.rlVertex3f(x + half_width, y + half_height, z - half_length)

    rlgl.rlNormal3f(0.0, -1.0, 0.0)
    rlgl.rlTexCoord2f((source.x + source.width) / tex_width, source.y / tex_height)
    rlgl.rlVertex3f(x - half_width, y - half_height, z - half_length)
    rlgl.rlTexCoord2f(source.x / tex_width, source.y / tex_height)
    rlgl.rlVertex3f(x + half_width, y - half_height, z - half_length)
    rlgl.rlTexCoord2f(source.x / tex_width, (source.y + source.height) / tex_height)
    rlgl.rlVertex3f(x + half_width, y - half_height, z + half_length)
    rlgl.rlTexCoord2f((source.x + source.width) / tex_width, (source.y + source.height) / tex_height)
    rlgl.rlVertex3f(x - half_width, y - half_height, z + half_length)

    rlgl.rlNormal3f(1.0, 0.0, 0.0)
    rlgl.rlTexCoord2f((source.x + source.width) / tex_width, (source.y + source.height) / tex_height)
    rlgl.rlVertex3f(x + half_width, y - half_height, z - half_length)
    rlgl.rlTexCoord2f((source.x + source.width) / tex_width, source.y / tex_height)
    rlgl.rlVertex3f(x + half_width, y + half_height, z - half_length)
    rlgl.rlTexCoord2f(source.x / tex_width, source.y / tex_height)
    rlgl.rlVertex3f(x + half_width, y + half_height, z + half_length)
    rlgl.rlTexCoord2f(source.x / tex_width, (source.y + source.height) / tex_height)
    rlgl.rlVertex3f(x + half_width, y - half_height, z + half_length)

    rlgl.rlNormal3f(-1.0, 0.0, 0.0)
    rlgl.rlTexCoord2f(source.x / tex_width, (source.y + source.height) / tex_height)
    rlgl.rlVertex3f(x - half_width, y - half_height, z - half_length)
    rlgl.rlTexCoord2f((source.x + source.width) / tex_width, (source.y + source.height) / tex_height)
    rlgl.rlVertex3f(x - half_width, y - half_height, z + half_length)
    rlgl.rlTexCoord2f((source.x + source.width) / tex_width, source.y / tex_height)
    rlgl.rlVertex3f(x - half_width, y + half_height, z + half_length)
    rlgl.rlTexCoord2f(source.x / tex_width, source.y / tex_height)
    rlgl.rlVertex3f(x - half_width, y + half_height, z - half_length)

    rlgl.rlEnd()
    rlgl.rlSetTexture(u32<-0)

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let camera = rl.Camera3D(
        position = rl.Vector3(x = 0.0, y = 10.0, z = 10.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let texture = rl.LoadTexture(texture_path)
    defer rl.UnloadTexture(texture)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)

        draw_cube_texture(texture, rl.Vector3(x = -2.0, y = 2.0, z = 0.0), 2.0, 4.0, 2.0, rl.WHITE)

        let source = rl.Rectangle(
            x = 0.0,
            y = f32<-texture.height / 2.0,
            width = f32<-texture.width / 2.0,
            height = f32<-texture.height / 2.0,
        )
        draw_cube_texture_rec(texture, source, rl.Vector3(x = 2.0, y = 1.0, z = 0.0), 2.0, 2.0, 2.0, rl.WHITE)

        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()
        rl.DrawFPS(10, 10)

    return 0