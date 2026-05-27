import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - world screen")
    defer rl.close_window()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 10.0, y = 10.0, z = 10.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )
    let cube_position = rl.Vector3(x = 0.0, y = 0.0, z = 0.0)
    var cube_screen_position = rl.Vector2(x = 0.0, y = 0.0)

    rl.disable_cursor()
    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_THIRD_PERSON)
        cube_screen_position = rl.get_world_to_screen(
            rl.Vector3(x = cube_position.x, y = cube_position.y + 2.5, z = cube_position.z),
            camera,
        )

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_cube(cube_position, 2.0, 2.0, 2.0, rl.RED)
        rl.draw_cube_wires(cube_position, 2.0, 2.0, 2.0, rl.MAROON)
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        let enemy_label = "Enemy: 100/100"
        rl.draw_text(enemy_label, (int<-cube_screen_position.x) - (rl.measure_text(enemy_label, 20) / 2), int<-cube_screen_position.y, 20, rl.BLACK)

        rl.draw_text(f"Cube position in screen space coordinates: [#{int<-cube_screen_position.x}, #{int<-cube_screen_position.y}]", 10, 10, 20, rl.LIME)
        rl.draw_text("Text 2d should be always on top of the cube", 10, 40, 20, rl.GRAY)

        rl.end_drawing()

    return 0
