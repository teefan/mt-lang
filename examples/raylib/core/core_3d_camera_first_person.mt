module examples.raylib.core.core_3d_camera_first_person

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const max_columns: i32 = 20
const window_title: cstr = c"raylib [core] example - 3d camera first person"
const controls_title: cstr = c"Camera controls:"
const controls_move: cstr = c"- Move keys: W, A, S, D, Space, Left-Ctrl"
const controls_look: cstr = c"- Look around: arrow keys or mouse"
const controls_modes: cstr = c"- Camera mode keys: 1, 2, 3, 4"
const controls_zoom: cstr = c"- Zoom keys: num-plus, num-minus or mouse scroll"
const controls_projection: cstr = c"- Camera projection key: P"

def camera_mode_text(camera_mode: i32) -> cstr:
    if camera_mode == rl.CameraMode.CAMERA_FREE:
        return c"Mode: FREE"
    if camera_mode == rl.CameraMode.CAMERA_FIRST_PERSON:
        return c"Mode: FIRST_PERSON"
    if camera_mode == rl.CameraMode.CAMERA_THIRD_PERSON:
        return c"Mode: THIRD_PERSON"
    if camera_mode == rl.CameraMode.CAMERA_ORBITAL:
        return c"Mode: ORBITAL"
    return c"Mode: CUSTOM"

def projection_text(projection: i32) -> cstr:
    if projection == rl.CameraProjection.CAMERA_PERSPECTIVE:
        return c"Projection: PERSPECTIVE"
    if projection == rl.CameraProjection.CAMERA_ORTHOGRAPHIC:
        return c"Projection: ORTHOGRAPHIC"
    return c"Projection: CUSTOM"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 0.0, y = 2.0, z = 4.0),
        target = rl.Vector3(x = 0.0, y = 2.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 60.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )
    var camera_mode = rl.CameraMode.CAMERA_FIRST_PERSON

    var heights = array[f32, 20](
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
    )
    var positions = array[rl.Vector3, 20](
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
    )
    var colors = array[rl.Color, 20](
        rl.BLACK, rl.BLACK, rl.BLACK, rl.BLACK, rl.BLACK, rl.BLACK, rl.BLACK, rl.BLACK, rl.BLACK, rl.BLACK,
        rl.BLACK, rl.BLACK, rl.BLACK, rl.BLACK, rl.BLACK, rl.BLACK, rl.BLACK, rl.BLACK, rl.BLACK, rl.BLACK,
    )

    for index in range(0, max_columns):
        heights[index] = cast[f32](rl.GetRandomValue(1, 12))
        positions[index] = rl.Vector3(
            x = rl.GetRandomValue(-15, 15),
            y = heights[index] / 2.0,
            z = rl.GetRandomValue(-15, 15),
        )
        colors[index] = rl.Color(
            r = rl.GetRandomValue(20, 255),
            g = rl.GetRandomValue(10, 55),
            b = 30,
            a = 255,
        )

    let overlay_alpha: f32 = 0.5

    rl.DisableCursor()
    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_ONE):
            camera_mode = rl.CameraMode.CAMERA_FREE
            camera.up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_TWO):
            camera_mode = rl.CameraMode.CAMERA_FIRST_PERSON
            camera.up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_THREE):
            camera_mode = rl.CameraMode.CAMERA_THIRD_PERSON
            camera.up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
        if rl.IsKeyPressed(rl.KeyboardKey.KEY_FOUR):
            camera_mode = rl.CameraMode.CAMERA_ORBITAL
            camera.up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_P):
            if camera.projection == rl.CameraProjection.CAMERA_PERSPECTIVE:
                camera_mode = rl.CameraMode.CAMERA_THIRD_PERSON
                camera.position = rl.Vector3(x = 0.0, y = 2.0, z = -100.0)
                camera.target = rl.Vector3(x = 0.0, y = 2.0, z = 0.0)
                camera.up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
                camera.projection = rl.CameraProjection.CAMERA_ORTHOGRAPHIC
                camera.fovy = 20.0
            else:
                camera_mode = rl.CameraMode.CAMERA_THIRD_PERSON
                camera.position = rl.Vector3(x = 0.0, y = 2.0, z = 10.0)
                camera.target = rl.Vector3(x = 0.0, y = 2.0, z = 0.0)
                camera.up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
                camera.projection = rl.CameraProjection.CAMERA_PERSPECTIVE
                camera.fovy = 60.0

        rl.UpdateCamera(&camera, camera_mode)

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)
        rl.DrawPlane(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector2(x = 32.0, y = 32.0), rl.LIGHTGRAY)
        rl.DrawCube(rl.Vector3(x = -16.0, y = 2.5, z = 0.0), 1.0, 5.0, 32.0, rl.BLUE)
        rl.DrawCube(rl.Vector3(x = 16.0, y = 2.5, z = 0.0), 1.0, 5.0, 32.0, rl.LIME)
        rl.DrawCube(rl.Vector3(x = 0.0, y = 2.5, z = 16.0), 32.0, 5.0, 1.0, rl.GOLD)

        for index in range(0, max_columns):
            rl.DrawCube(positions[index], 2.0, heights[index], 2.0, colors[index])
            rl.DrawCubeWires(positions[index], 2.0, heights[index], 2.0, rl.MAROON)

        if camera_mode == rl.CameraMode.CAMERA_THIRD_PERSON:
            rl.DrawCube(camera.target, 0.5, 0.5, 0.5, rl.PURPLE)
            rl.DrawCubeWires(camera.target, 0.5, 0.5, 0.5, rl.DARKPURPLE)

        rl.EndMode3D()

        rl.DrawRectangle(5, 5, 330, 100, rl.Fade(rl.SKYBLUE, overlay_alpha))
        rl.DrawRectangleLines(5, 5, 330, 100, rl.BLUE)
        rl.DrawText(controls_title, 15, 15, 10, rl.BLACK)
        rl.DrawText(controls_move, 15, 30, 10, rl.BLACK)
        rl.DrawText(controls_look, 15, 45, 10, rl.BLACK)
        rl.DrawText(controls_modes, 15, 60, 10, rl.BLACK)
        rl.DrawText(controls_zoom, 15, 75, 10, rl.BLACK)
        rl.DrawText(controls_projection, 15, 90, 10, rl.BLACK)

        rl.DrawRectangle(600, 5, 195, 100, rl.Fade(rl.SKYBLUE, overlay_alpha))
        rl.DrawRectangleLines(600, 5, 195, 100, rl.BLUE)
        rl.DrawText(c"Camera status:", 610, 15, 10, rl.BLACK)
        rl.DrawText(camera_mode_text(camera_mode), 610, 30, 10, rl.BLACK)
        rl.DrawText(projection_text(camera.projection), 610, 45, 10, rl.BLACK)

    return 0
