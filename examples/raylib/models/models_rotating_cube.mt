module examples.raylib.models.models_rotating_cube

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [models] example - rotating cube"
const texture_path: cstr = c"../resources/cubicmap_atlas.png"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let camera = rl.Camera3D(
        position = rl.Vector3(x = 0.0, y = 3.0, z = 3.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var model = rl.LoadModelFromMesh(rl.GenMeshCube(1.0, 1.0, 1.0))
    defer rl.UnloadModel(model)

    let image = rl.LoadImage(texture_path)
    let crop = rl.ImageFromImage(
        image,
        rl.Rectangle(
            x = 0.0,
            y = image.height / 2.0,
            width = image.width / 2.0,
            height = image.height / 2.0,
        ),
    )
    let texture = rl.LoadTextureFromImage(crop)
    defer rl.UnloadTexture(texture)
    rl.UnloadImage(image)
    rl.UnloadImage(crop)

    rl.SetMaterialTexture(model.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    var rotation = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rotation += 1.0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)

        rl.DrawModelEx(
            model,
            rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
            rl.Vector3(x = 0.5, y = 1.0, z = 0.0),
            rotation,
            rl.Vector3(x = 1.0, y = 1.0, z = 1.0),
            rl.WHITE,
        )
        rl.DrawGrid(10, 1.0)

        rl.EndMode3D()
        rl.DrawFPS(10, 10)

    return 0