module examples.raylib.models.models_tesseract_view

import std.c.libm as math
import std.c.raylib as rl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const vertex_count: i32 = 16
const window_title: cstr = c"raylib [models] example - tesseract view"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let camera = rl.Camera3D(
        position = rl.Vector3(x = 4.0, y = 4.0, z = 4.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 0.0, z = 1.0),
        fovy = 50.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var tesseract = zero[array[rl.Vector4, 16]]()
    tesseract[0] = rl.Vector4(x = 1.0, y = 1.0, z = 1.0, w = 1.0)
    tesseract[1] = rl.Vector4(x = 1.0, y = 1.0, z = 1.0, w = -1.0)
    tesseract[2] = rl.Vector4(x = 1.0, y = 1.0, z = -1.0, w = 1.0)
    tesseract[3] = rl.Vector4(x = 1.0, y = 1.0, z = -1.0, w = -1.0)
    tesseract[4] = rl.Vector4(x = 1.0, y = -1.0, z = 1.0, w = 1.0)
    tesseract[5] = rl.Vector4(x = 1.0, y = -1.0, z = 1.0, w = -1.0)
    tesseract[6] = rl.Vector4(x = 1.0, y = -1.0, z = -1.0, w = 1.0)
    tesseract[7] = rl.Vector4(x = 1.0, y = -1.0, z = -1.0, w = -1.0)
    tesseract[8] = rl.Vector4(x = -1.0, y = 1.0, z = 1.0, w = 1.0)
    tesseract[9] = rl.Vector4(x = -1.0, y = 1.0, z = 1.0, w = -1.0)
    tesseract[10] = rl.Vector4(x = -1.0, y = 1.0, z = -1.0, w = 1.0)
    tesseract[11] = rl.Vector4(x = -1.0, y = 1.0, z = -1.0, w = -1.0)
    tesseract[12] = rl.Vector4(x = -1.0, y = -1.0, z = 1.0, w = 1.0)
    tesseract[13] = rl.Vector4(x = -1.0, y = -1.0, z = 1.0, w = -1.0)
    tesseract[14] = rl.Vector4(x = -1.0, y = -1.0, z = -1.0, w = 1.0)
    tesseract[15] = rl.Vector4(x = -1.0, y = -1.0, z = -1.0, w = -1.0)

    var transformed = zero[array[rl.Vector3, 16]]()
    var w_values = zero[array[f32, 16]]()

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let rotation = rm.deg2rad * 45.0 * f32<-rl.GetTime()

        for index in 0..vertex_count:
            var point = tesseract[index]
            let rotated_xw = rl.Vector2(x = point.x, y = point.w).rotate(rotation)
            point.x = rotated_xw.x
            point.w = rotated_xw.y

            let c = 3.0 / (3.0 - point.w)
            point.x *= c
            point.y *= c
            point.z *= c

            transformed[index] = rl.Vector3(x = point.x, y = point.y, z = point.z)
            w_values[index] = point.w

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)

        for i in 0..vertex_count:
            rl.DrawSphere(transformed[i], math.fabsf(w_values[i] * 0.1), rl.RED)

            for j in 0..vertex_count:
                let v1 = tesseract[i]
                let v2 = tesseract[j]
                var diff = 0
                if v1.x == v2.x:
                    diff += 1
                if v1.y == v2.y:
                    diff += 1
                if v1.z == v2.z:
                    diff += 1
                if v1.w == v2.w:
                    diff += 1

                if diff == 3 and i < j:
                    rl.DrawLine3D(transformed[i], transformed[j], rl.MAROON)

        rl.EndMode3D()

    return 0
