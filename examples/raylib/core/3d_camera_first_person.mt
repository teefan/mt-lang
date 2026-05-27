import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const MAX_COLUMNS: int = 20


function camera_mode_name(mode: rl.CameraMode) -> str:
    if mode == rl.CameraMode.CAMERA_FREE:
        return "FREE"
    if mode == rl.CameraMode.CAMERA_FIRST_PERSON:
        return "FIRST_PERSON"
    if mode == rl.CameraMode.CAMERA_THIRD_PERSON:
        return "THIRD_PERSON"
    if mode == rl.CameraMode.CAMERA_ORBITAL:
        return "ORBITAL"

    return "CUSTOM"


function projection_name(projection: int) -> str:
    if projection == int<-rl.CameraProjection.CAMERA_PERSPECTIVE:
        return "PERSPECTIVE"
    if projection == int<-rl.CameraProjection.CAMERA_ORTHOGRAPHIC:
        return "ORTHOGRAPHIC"

    return "CUSTOM"


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - 3d camera first person")
    defer rl.close_window()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 0.0, y = 2.0, z = 4.0),
        target = rl.Vector3(x = 0.0, y = 2.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 60.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )
    var camera_mode = rl.CameraMode.CAMERA_FIRST_PERSON

    var heights: array[float, MAX_COLUMNS] = zero[array[float, MAX_COLUMNS]]
    var positions: array[rl.Vector3, MAX_COLUMNS] = zero[array[rl.Vector3, MAX_COLUMNS]]
    var colors: array[rl.Color, MAX_COLUMNS] = zero[array[rl.Color, MAX_COLUMNS]]

    var index = 0
    while index < MAX_COLUMNS:
        heights[index] = float<-rl.get_random_value(1, 12)
        positions[index] = rl.Vector3(
            x = float<-rl.get_random_value(-15, 15),
            y = heights[index] / 2.0,
            z = float<-rl.get_random_value(-15, 15),
        )
        colors[index] = rl.Color(
            r = ubyte<-rl.get_random_value(20, 255),
            g = ubyte<-rl.get_random_value(10, 55),
            b = ubyte<-30,
            a = ubyte<-255,
        )
        index += 1

    rl.disable_cursor()
    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_ONE):
            camera_mode = rl.CameraMode.CAMERA_FREE
            camera.up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_TWO):
            camera_mode = rl.CameraMode.CAMERA_FIRST_PERSON
            camera.up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_THREE):
            camera_mode = rl.CameraMode.CAMERA_THIRD_PERSON
            camera.up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_FOUR):
            camera_mode = rl.CameraMode.CAMERA_ORBITAL
            camera.up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_P):
            if camera.projection == int<-rl.CameraProjection.CAMERA_PERSPECTIVE:
                camera_mode = rl.CameraMode.CAMERA_THIRD_PERSON
                camera.position = rl.Vector3(x = 100.0, y = 102.0, z = 100.0)
                camera.target = rl.Vector3(x = 0.0, y = 2.0, z = 0.0)
                camera.up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
                camera.projection = int<-rl.CameraProjection.CAMERA_ORTHOGRAPHIC
                camera.fovy = 20.0
            else if camera.projection == int<-rl.CameraProjection.CAMERA_ORTHOGRAPHIC:
                camera_mode = rl.CameraMode.CAMERA_THIRD_PERSON
                camera.position = rl.Vector3(x = 0.0, y = 2.0, z = 10.0)
                camera.target = rl.Vector3(x = 0.0, y = 2.0, z = 0.0)
                camera.up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
                camera.projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
                camera.fovy = 60.0

        rl.update_camera(camera, camera_mode)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_plane(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector2(x = 32.0, y = 32.0), rl.LIGHTGRAY)
        rl.draw_cube(rl.Vector3(x = -16.0, y = 2.5, z = 0.0), 1.0, 5.0, 32.0, rl.BLUE)
        rl.draw_cube(rl.Vector3(x = 16.0, y = 2.5, z = 0.0), 1.0, 5.0, 32.0, rl.LIME)
        rl.draw_cube(rl.Vector3(x = 0.0, y = 2.5, z = 16.0), 32.0, 5.0, 1.0, rl.GOLD)

        index = 0
        while index < MAX_COLUMNS:
            rl.draw_cube(positions[index], 2.0, heights[index], 2.0, colors[index])
            rl.draw_cube_wires(positions[index], 2.0, heights[index], 2.0, rl.MAROON)
            index += 1

        if camera_mode == rl.CameraMode.CAMERA_THIRD_PERSON:
            rl.draw_cube(camera.target, 0.5, 0.5, 0.5, rl.PURPLE)
            rl.draw_cube_wires(camera.target, 0.5, 0.5, 0.5, rl.DARKPURPLE)

        rl.end_mode_3d()

        rl.draw_rectangle(5, 5, 330, 100, rl.fade(rl.SKYBLUE, 0.5))
        rl.draw_rectangle_lines(5, 5, 330, 100, rl.BLUE)
        rl.draw_text("Camera controls:", 15, 15, 10, rl.BLACK)
        rl.draw_text("- Move keys: W, A, S, D, Space, Left-Ctrl", 15, 30, 10, rl.BLACK)
        rl.draw_text("- Look around: arrow keys or mouse", 15, 45, 10, rl.BLACK)
        rl.draw_text("- Camera mode keys: 1, 2, 3, 4", 15, 60, 10, rl.BLACK)
        rl.draw_text("- Zoom keys: num-plus, num-minus or mouse scroll", 15, 75, 10, rl.BLACK)
        rl.draw_text("- Camera projection key: P", 15, 90, 10, rl.BLACK)

        rl.draw_rectangle(600, 5, 195, 100, rl.fade(rl.SKYBLUE, 0.5))
        rl.draw_rectangle_lines(600, 5, 195, 100, rl.BLUE)
        rl.draw_text("Camera status:", 610, 15, 10, rl.BLACK)
        rl.draw_text(f"- Mode: #{camera_mode_name(camera_mode)}", 610, 30, 10, rl.BLACK)
        rl.draw_text(f"- Projection: #{projection_name(camera.projection)}", 610, 45, 10, rl.BLACK)
        rl.draw_text(f"- Position: (#{camera.position.x}, #{camera.position.y}, #{camera.position.z})", 610, 60, 10, rl.BLACK)
        rl.draw_text(f"- Target: (#{camera.target.x}, #{camera.target.y}, #{camera.target.z})", 610, 75, 10, rl.BLACK)
        rl.draw_text(f"- Up: (#{camera.up.x}, #{camera.up.y}, #{camera.up.z})", 610, 90, 10, rl.BLACK)
        rl.end_drawing()

    return 0
