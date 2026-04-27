module examples.raylib.models.models_cubicmap_rendering

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [models] example - cubicmap rendering"
const cubicmap_path: cstr = c"resources/cubicmap.png"
const atlas_path: cstr = c"resources/cubicmap_atlas.png"
const cubicmap_caption_top: cstr = c"cubicmap image used to"
const cubicmap_caption_bottom: cstr = c"generate map 3d model"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 16.0, y = 14.0, z = 16.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let image = rl.LoadImage(cubicmap_path)
    defer rl.UnloadImage(image)

    let cubicmap = rl.LoadTextureFromImage(image)
    defer rl.UnloadTexture(cubicmap)

    let mesh = rl.GenMeshCubicmap(image, rl.Vector3(x = 1.0, y = 1.0, z = 1.0))
    let model = rl.LoadModelFromMesh(mesh)
    defer rl.UnloadModel(model)

    let texture = rl.LoadTexture(atlas_path)
    defer rl.UnloadTexture(texture)

    rl.SetMaterialTexture(model.materials, cast[i32](rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO), texture)

    let map_position = rl.Vector3(x = -16.0, y = 0.0, z = -8.0)
    var pause = false

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_P):
            pause = not pause

        if not pause:
            rl.UpdateCamera(raw(addr(camera)), rl.CameraMode.CAMERA_ORBITAL)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode3D(camera)
        rl.DrawModel(model, map_position, 1.0, rl.WHITE)
        rl.EndMode3D()

        let cubicmap_position = rl.Vector2(
            x = cast[f32](screen_width) - cast[f32](cubicmap.width) * 4.0 - 20.0,
            y = 20.0,
        )
        rl.DrawTextureEx(cubicmap, cubicmap_position, 0.0, 4.0, rl.WHITE)
        rl.DrawRectangleLines(screen_width - cubicmap.width * 4 - 20, 20, cubicmap.width * 4, cubicmap.height * 4, rl.GREEN)

        rl.DrawText(cubicmap_caption_top, 658, 90, 10, rl.GRAY)
        rl.DrawText(cubicmap_caption_bottom, 658, 104, 10, rl.GRAY)
        rl.DrawFPS(10, 10)

    return 0
