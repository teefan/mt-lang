module examples.raylib.models.models_billboard_rendering

import std.c.libm as math
import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [models] example - billboard rendering"
const billboard_path: cstr = c"../resources/billboard.png"


def vector3_distance(left: rl.Vector3, right: rl.Vector3) -> f32:
    let dx = right.x - left.x
    let dy = right.y - left.y
    let dz = right.z - left.z
    return math.sqrtf(dx * dx + dy * dy + dz * dz)


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 5.0, y = 4.0, z = 5.0),
        target = rl.Vector3(x = 0.0, y = 2.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let bill = rl.LoadTexture(billboard_path)
    defer rl.UnloadTexture(bill)

    let bill_position_static = rl.Vector3(x = 0.0, y = 2.0, z = 0.0)
    let bill_position_rotating = rl.Vector3(x = 1.0, y = 2.0, z = 1.0)
    let source = rl.Rectangle(x = 0.0, y = 0.0, width = f32<-bill.width, height = f32<-bill.height)
    let bill_up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
    let size = rl.Vector2(x = source.width / source.height, y = 1.0)
    let origin = rl.Vector2(x = size.x * 0.5, y = size.y * 0.5)

    var distance_static: f32 = 0.0
    var distance_rotating: f32 = 0.0
    var rotation: f32 = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(ref_of(camera)), rl.CameraMode.CAMERA_ORBITAL)

        rotation += 0.4
        distance_static = vector3_distance(camera.position, bill_position_static)
        distance_rotating = vector3_distance(camera.position, bill_position_rotating)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)

        rl.DrawGrid(10, 1.0)

        if distance_static > distance_rotating:
            rl.DrawBillboard(camera, bill, bill_position_static, 2.0, rl.WHITE)
            rl.DrawBillboardPro(camera, bill, source, bill_position_rotating, bill_up, size, origin, rotation, rl.WHITE)
        else:
            rl.DrawBillboardPro(camera, bill, source, bill_position_rotating, bill_up, size, origin, rotation, rl.WHITE)
            rl.DrawBillboard(camera, bill, bill_position_static, 2.0, rl.WHITE)

        rl.EndMode3D()

        rl.DrawFPS(10, 10)

    return 0
