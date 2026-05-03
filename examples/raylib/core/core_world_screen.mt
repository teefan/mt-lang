module examples.raylib.core.core_world_screen

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - world screen"
const enemy_text: cstr = c"Enemy: 100/100"
const help_text: cstr = c"Text 2d should be always on top of the cube"

def main() -> i32:
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
    var cube_screen_position = rl.Vector2(x = 0.0, y = 0.0)

    rl.DisableCursor()
    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(ptr_of(ref_of(camera)), rl.CameraMode.CAMERA_THIRD_PERSON)
        cube_screen_position = rl.GetWorldToScreen(
            rl.Vector3(x = cube_position.x, y = cube_position.y + 2.5, z = cube_position.z),
            camera,
        )

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)
        rl.DrawCube(cube_position, 2.0, 2.0, 2.0, rl.RED)
        rl.DrawCubeWires(cube_position, 2.0, 2.0, 2.0, rl.MAROON)
        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()
        rl.DrawText(
            enemy_text,
            cube_screen_position.x - rl.MeasureText(enemy_text, 20) / 2,
            cube_screen_position.y,
            20,
            rl.BLACK,
        )
        rl.DrawText(rl.TextFormat(c"Cube position in screen space coordinates: [%i, %i]", i32<-cube_screen_position.x, i32<-cube_screen_position.y), 10, 10, 20, rl.LIME)
        rl.DrawText(help_text, 10, 40, 20, rl.GRAY)

    return 0