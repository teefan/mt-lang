import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const FOVY_PERSPECTIVE: float = 45.0
const WIDTH_ORTHOGRAPHIC: float = 10.0


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - orthographic projection")
    defer rl.close_window()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 0.0, y = 10.0, z = 10.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = FOVY_PERSPECTIVE,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_pressed(rl.KeyboardKey.KEY_SPACE):
            if camera.projection == int<-rl.CameraProjection.CAMERA_PERSPECTIVE:
                camera.fovy = WIDTH_ORTHOGRAPHIC
                camera.projection = int<-rl.CameraProjection.CAMERA_ORTHOGRAPHIC
            else:
                camera.fovy = FOVY_PERSPECTIVE
                camera.projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_cube(rl.Vector3(x = -4.0, y = 0.0, z = 2.0), 2.0, 5.0, 2.0, rl.RED)
        rl.draw_cube_wires(rl.Vector3(x = -4.0, y = 0.0, z = 2.0), 2.0, 5.0, 2.0, rl.GOLD)
        rl.draw_cube_wires(rl.Vector3(x = -4.0, y = 0.0, z = -2.0), 3.0, 6.0, 2.0, rl.MAROON)
        rl.draw_sphere(rl.Vector3(x = -1.0, y = 0.0, z = -2.0), 1.0, rl.GREEN)
        rl.draw_sphere_wires(rl.Vector3(x = 1.0, y = 0.0, z = 2.0), 2.0, 16, 16, rl.LIME)
        rl.draw_cylinder(rl.Vector3(x = 4.0, y = 0.0, z = -2.0), 1.0, 2.0, 3.0, 4, rl.SKYBLUE)
        rl.draw_cylinder_wires(rl.Vector3(x = 4.0, y = 0.0, z = -2.0), 1.0, 2.0, 3.0, 4, rl.DARKBLUE)
        rl.draw_cylinder_wires(rl.Vector3(x = 4.5, y = -1.0, z = 2.0), 1.0, 1.0, 2.0, 6, rl.BROWN)
        rl.draw_cylinder(rl.Vector3(x = 1.0, y = 0.0, z = -4.0), 0.0, 1.5, 3.0, 8, rl.GOLD)
        rl.draw_cylinder_wires(rl.Vector3(x = 1.0, y = 0.0, z = -4.0), 0.0, 1.5, 3.0, 8, rl.PINK)
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        rl.draw_text("Press Spacebar to switch camera type", 10, rl.get_screen_height() - 30, 20, rl.DARKGRAY)

        if camera.projection == int<-rl.CameraProjection.CAMERA_ORTHOGRAPHIC:
            rl.draw_text("ORTHOGRAPHIC", 10, 40, 20, rl.BLACK)
        else:
            rl.draw_text("PERSPECTIVE", 10, 40, 20, rl.BLACK)

        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
