module examples.raylib.core.core_3d_camera_free

import std.c.raylib as rl

const screen_width: int = 800
const screen_height: int = 450
const window_title: cstr = c"raylib [core] example - 3d camera free"
const controls_title: cstr = c"Free camera default controls:"
const controls_zoom: cstr = c"- Mouse Wheel to Zoom in-out"
const controls_pan: cstr = c"- Mouse Wheel Pressed to Pan"
const controls_reset: cstr = c"- Z to zoom to (0, 0, 0)"


def main() -> int:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 10.0, y = 10.0, z = 10.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )
    let cube_position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
    let overlay_alpha: float = 0.5

    rl.DisableCursor()
    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(camera), rl.CameraMode.CAMERA_FREE)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_Z):
            camera.target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)
        rl.DrawCube(cube_position, 2.0, 2.0, 2.0, rl.RED)
        rl.DrawCubeWires(cube_position, 2.0, 2.0, 2.0, rl.MAROON)
        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()
        rl.DrawRectangle(10, 10, 320, 93, rl.Fade(rl.SKYBLUE, overlay_alpha))
        rl.DrawRectangleLines(10, 10, 320, 93, rl.BLUE)
        rl.DrawText(controls_title, 20, 20, 10, rl.BLACK)
        rl.DrawText(controls_zoom, 40, 40, 10, rl.DARKGRAY)
        rl.DrawText(controls_pan, 40, 60, 10, rl.DARKGRAY)
        rl.DrawText(controls_reset, 40, 80, 10, rl.DARKGRAY)

    return 0
