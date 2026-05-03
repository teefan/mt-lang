module examples.raylib.models.models_heightmap_rendering

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [models] example - heightmap rendering"
const heightmap_path: cstr = c"../resources/heightmap.png"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 18.0, y = 21.0, z = 18.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let image = rl.LoadImage(heightmap_path)
    let texture = rl.LoadTextureFromImage(image)
    defer rl.UnloadTexture(texture)

    let mesh = rl.GenMeshHeightmap(image, rl.Vector3(x = 16.0, y = 8.0, z = 16.0))
    let model = rl.LoadModelFromMesh(mesh)
    defer rl.UnloadModel(model)

    rl.SetMaterialTexture(model.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    let map_position = rl.Vector3(x = -8.0, y = 0.0, z = -8.0)

    rl.UnloadImage(image)

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(ref_of(camera)), rl.CameraMode.CAMERA_ORBITAL)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode3D(camera)
        rl.DrawModel(model, map_position, 1.0, rl.RED)
        rl.DrawGrid(20, 1.0)
        rl.EndMode3D()

        rl.DrawTexture(texture, screen_width - texture.width - 20, 20, rl.WHITE)
        rl.DrawRectangleLines(screen_width - texture.width - 20, 20, texture.width, texture.height, rl.GREEN)
        rl.DrawFPS(10, 10)

    return 0