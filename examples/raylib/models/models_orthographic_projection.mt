module examples.raylib.models.models_orthographic_projection

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [models] example - orthographic projection"
const switch_camera_text: cstr = c"Press Spacebar to switch camera type"
const orthographic_text: cstr = c"ORTHOGRAPHIC"
const perspective_text: cstr = c"PERSPECTIVE"
const fovy_perspective: f32 = 45.0
const width_orthographic: f32 = 10.0


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 0.0, y = 10.0, z = 10.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = fovy_perspective,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_SPACE):
            if camera.projection == rl.CameraProjection.CAMERA_PERSPECTIVE:
                camera.fovy = width_orthographic
                camera.projection = rl.CameraProjection.CAMERA_ORTHOGRAPHIC
            else:
                camera.fovy = fovy_perspective
                camera.projection = rl.CameraProjection.CAMERA_PERSPECTIVE

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)

        rl.DrawCube(rl.Vector3(x = -4.0, y = 0.0, z = 2.0), 2.0, 5.0, 2.0, rl.RED)
        rl.DrawCubeWires(rl.Vector3(x = -4.0, y = 0.0, z = 2.0), 2.0, 5.0, 2.0, rl.GOLD)
        rl.DrawCubeWires(rl.Vector3(x = -4.0, y = 0.0, z = -2.0), 3.0, 6.0, 2.0, rl.MAROON)

        rl.DrawSphere(rl.Vector3(x = -1.0, y = 0.0, z = -2.0), 1.0, rl.GREEN)
        rl.DrawSphereWires(rl.Vector3(x = 1.0, y = 0.0, z = 2.0), 2.0, 16, 16, rl.LIME)

        rl.DrawCylinder(rl.Vector3(x = 4.0, y = 0.0, z = -2.0), 1.0, 2.0, 3.0, 4, rl.SKYBLUE)
        rl.DrawCylinderWires(rl.Vector3(x = 4.0, y = 0.0, z = -2.0), 1.0, 2.0, 3.0, 4, rl.DARKBLUE)
        rl.DrawCylinderWires(rl.Vector3(x = 4.5, y = -1.0, z = 2.0), 1.0, 1.0, 2.0, 6, rl.BROWN)

        rl.DrawCylinder(rl.Vector3(x = 1.0, y = 0.0, z = -4.0), 0.0, 1.5, 3.0, 8, rl.GOLD)
        rl.DrawCylinderWires(rl.Vector3(x = 1.0, y = 0.0, z = -4.0), 0.0, 1.5, 3.0, 8, rl.PINK)

        rl.DrawGrid(10, 1.0)

        rl.EndMode3D()

        rl.DrawText(switch_camera_text, 10, screen_height - 30, 20, rl.DARKGRAY)

        if camera.projection == rl.CameraProjection.CAMERA_ORTHOGRAPHIC:
            rl.DrawText(orthographic_text, 10, 40, 20, rl.BLACK)
        elif camera.projection == rl.CameraProjection.CAMERA_PERSPECTIVE:
            rl.DrawText(perspective_text, 10, 40, 20, rl.BLACK)

        rl.DrawFPS(10, 10)

    return 0
