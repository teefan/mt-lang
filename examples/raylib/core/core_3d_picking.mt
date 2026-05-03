module examples.raylib.core.core_3d_picking

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - 3d picking"
const help_text: cstr = c"Try clicking on the box with your mouse!"
const toggle_text: cstr = c"Right click mouse to toggle camera controls"
const selected_text: cstr = c"BOX SELECTED"


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
    let cube_position = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
    let cube_size = rl.Vector3(x = 2.0, y = 2.0, z = 2.0)
    var ray = rl.Ray(
        position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        direction = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
    )
    var collision = rl.RayCollision(
        hit = false,
        distance = 0.0,
        point = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        normal = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
    )
    let selection_bounds = rl.BoundingBox(
        min = rl.Vector3(
            x = cube_position.x - cube_size.x / 2.0,
            y = cube_position.y - cube_size.y / 2.0,
            z = cube_position.z - cube_size.z / 2.0,
        ),
        max = rl.Vector3(
            x = cube_position.x + cube_size.x / 2.0,
            y = cube_position.y + cube_size.y / 2.0,
            z = cube_position.z + cube_size.z / 2.0,
        ),
    )

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsCursorHidden():
            rl.UpdateCamera(ptr_of(ref_of(camera)), rl.CameraMode.CAMERA_FIRST_PERSON)

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            if rl.IsCursorHidden():
                rl.EnableCursor()
            else:
                rl.DisableCursor()

        if rl.IsMouseButtonPressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            if not collision.hit:
                ray = rl.GetScreenToWorldRay(rl.GetMousePosition(), camera)
                collision = rl.GetRayCollisionBox(ray, selection_bounds)
            else:
                collision.hit = false

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)

        if collision.hit:
            rl.DrawCube(cube_position, cube_size.x, cube_size.y, cube_size.z, rl.RED)
            rl.DrawCubeWires(cube_position, cube_size.x, cube_size.y, cube_size.z, rl.MAROON)
            rl.DrawCubeWires(cube_position, cube_size.x + 0.2, cube_size.y + 0.2, cube_size.z + 0.2, rl.GREEN)
        else:
            rl.DrawCube(cube_position, cube_size.x, cube_size.y, cube_size.z, rl.GRAY)
            rl.DrawCubeWires(cube_position, cube_size.x, cube_size.y, cube_size.z, rl.DARKGRAY)

        rl.DrawRay(ray, rl.MAROON)
        rl.DrawGrid(10, 1.0)
        rl.EndMode3D()

        rl.DrawText(help_text, 240, 10, 20, rl.DARKGRAY)
        if collision.hit:
            rl.DrawText(selected_text, 280, 45, 30, rl.GREEN)
        rl.DrawText(toggle_text, 10, 430, 10, rl.GRAY)
        rl.DrawFPS(10, 10)

    return 0
