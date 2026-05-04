module examples.raylib.models.models_basic_voxel

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const world_size: i32 = 8
const voxel_count: i32 = world_size * world_size * world_size
const window_title: cstr = c"raylib [models] example - basic voxel"
const remove_text: cstr = c"Left-click a voxel to remove it!"
const move_text: cstr = c"WASD to move, mouse to look around"


def voxel_index(x: i32, y: i32, z: i32) -> i32:
    return x * world_size * world_size + y * world_size + z


def voxel_position(x: i32, y: i32, z: i32) -> rl.Vector3:
    return rl.Vector3(x = f32<-x, y = f32<-y, z = f32<-z)


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    rl.DisableCursor()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = -2.0, y = 0.0, z = -2.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let cube_mesh = rl.GenMeshCube(1.0, 1.0, 1.0)
    let cube_model = rl.LoadModelFromMesh(cube_mesh)
    defer rl.UnloadModel(cube_model)

    var voxels = zero[array[bool, voxel_count]]()
    for index in 0..voxel_count:
        voxels[index] = true

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(ref_of(camera)), rl.CameraMode.CAMERA_FIRST_PERSON)

        if rl.IsMouseButtonPressed(i32<-rl.MouseButton.MOUSE_BUTTON_LEFT):
            let screen_center = rl.Vector2(x = rl.GetScreenWidth() / 2.0, y = rl.GetScreenHeight() / 2.0)
            let ray = rl.GetScreenToWorldRay(screen_center, camera)

            var closest_distance: f32 = 99999.0
            var closest_x = -1
            var closest_y = -1
            var closest_z = -1

            for x in 0..world_size:
                for y in 0..world_size:
                    for z in 0..world_size:
                        if not voxels[voxel_index(x, y, z)]:
                            continue

                        let position = voxel_position(x, y, z)
                        let box = rl.BoundingBox(
                            min = rl.Vector3(x = position.x - 0.5, y = position.y - 0.5, z = position.z - 0.5),
                            max = rl.Vector3(x = position.x + 0.5, y = position.y + 0.5, z = position.z + 0.5),
                        )
                        let collision = rl.GetRayCollisionBox(ray, box)

                        if collision.hit and collision.distance < closest_distance:
                            closest_distance = collision.distance
                            closest_x = x
                            closest_y = y
                            closest_z = z

            if closest_x >= 0:
                voxels[voxel_index(closest_x, closest_y, closest_z)] = false

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)

        rl.DrawGrid(10, 1.0)

        for x in 0..world_size:
            for y in 0..world_size:
                for z in 0..world_size:
                    if not voxels[voxel_index(x, y, z)]:
                        continue

                    let position = voxel_position(x, y, z)
                    rl.DrawModel(cube_model, position, 1.0, rl.BEIGE)
                    rl.DrawCubeWires(position, 1.0, 1.0, 1.0, rl.BLACK)

        rl.EndMode3D()

        rl.DrawCircle(rl.GetScreenWidth() / 2, rl.GetScreenHeight() / 2, 4.0, rl.RED)
        rl.DrawText(remove_text, 10, 10, 20, rl.DARKGRAY)
        rl.DrawText(move_text, 10, 35, 10, rl.GRAY)

    return 0
