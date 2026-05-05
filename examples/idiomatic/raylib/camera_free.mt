module examples.idiomatic.raylib.camera_free

import std.raylib as rl

const screen_width: int = 960
const screen_height: int = 540
const overlay_alpha: float = 0.45


def main() -> int:
    rl.init_window(screen_width, screen_height, "Milk Tea Free Camera")
    defer rl.close_window()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 10.0, y = 10.0, z = 10.0),
        target = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )
    let cube_position = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)

    rl.disable_cursor()
    defer rl.enable_cursor()
    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(inout camera, rl.CameraMode.CAMERA_FREE)

        if rl.is_key_pressed(rl.KeyboardKey.KEY_Z):
            camera.target = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)

        rl.begin_drawing()
        defer rl.end_drawing()

        rl.clear_background(rl.RAYWHITE)
        rl.begin_mode_3d(camera)
        rl.draw_cube(cube_position, 2.0, 2.0, 2.0, rl.RED)
        rl.draw_cube_wires(cube_position, 2.0, 2.0, 2.0, rl.MAROON)
        rl.draw_grid(20, 1.0)
        rl.end_mode_3d()

        rl.draw_rectangle(12, 12, 180, 44, rl.fade(rl.SKYBLUE, overlay_alpha))

    return 0
