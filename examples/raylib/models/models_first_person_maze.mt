module examples.raylib.models.models_first_person_maze

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [models] example - first person maze"
const cubicmap_path: cstr = c"../resources/cubicmap.png"
const atlas_path: cstr = c"../resources/cubicmap_atlas.png"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 0.2, y = 0.4, z = 0.2),
        target = rl.Vector3(x = 0.185, y = 0.4, z = 0.0),
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

    rl.SetMaterialTexture(model.materials, i32<-rl.MaterialMapIndex.MATERIAL_MAP_ALBEDO, texture)

    let map_pixels = rl.LoadImageColors(image)
    defer rl.UnloadImageColors(map_pixels)

    let map_position = rl.Vector3(x = -16.0, y = 0.0, z = -8.0)

    rl.DisableCursor()
    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let old_camera_position = camera.position

        rl.UpdateCamera(ptr_of(ref_of(camera)), rl.CameraMode.CAMERA_FIRST_PERSON)

        let player_pos = rl.Vector2(x = camera.position.x, y = camera.position.z)
        let player_radius: f32 = 0.1

        var player_cell_x = i32<-(player_pos.x - map_position.x + 0.5)
        var player_cell_y = i32<-(player_pos.y - map_position.z + 0.5)

        if player_cell_x < 0:
            player_cell_x = 0
        elif player_cell_x >= cubicmap.width:
            player_cell_x = cubicmap.width - 1

        if player_cell_y < 0:
            player_cell_y = 0
        elif player_cell_y >= cubicmap.height:
            player_cell_y = cubicmap.height - 1

        for y in range(player_cell_y - 1, player_cell_y + 2):
            if y >= 0 and y < cubicmap.height:
                for x in range(player_cell_x - 1, player_cell_x + 2):
                    if x >= 0 and x < cubicmap.width:
                        let cell = rl.Rectangle(
                            x = map_position.x - 0.5 + f32<-x,
                            y = map_position.z - 0.5 + f32<-y,
                            width = 1.0,
                            height = 1.0,
                        )
                        unsafe:
                            if map_pixels[(y * cubicmap.width) + x].r == u8<-255 and rl.CheckCollisionCircleRec(player_pos, player_radius, cell):
                                camera.position = old_camera_position

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)
        rl.DrawModel(model, map_position, 1.0, rl.WHITE)
        rl.EndMode3D()

        let radar_origin_x = screen_width - cubicmap.width * 4 - 20
        let radar_origin_y = 20
        rl.DrawTextureEx(
            cubicmap,
            rl.Vector2(x = f32<-radar_origin_x, y = f32<-radar_origin_y),
            0.0,
            4.0,
            rl.WHITE,
        )
        rl.DrawRectangleLines(radar_origin_x, radar_origin_y, cubicmap.width * 4, cubicmap.height * 4, rl.GREEN)
        rl.DrawRectangle(radar_origin_x + player_cell_x * 4, radar_origin_y + player_cell_y * 4, 4, 4, rl.RED)
        rl.DrawFPS(10, 10)

    return 0
