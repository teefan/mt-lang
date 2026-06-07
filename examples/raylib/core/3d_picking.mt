import std.raylib as rl

const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [core] example - 3d picking")
    defer rl.close_window()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 10.0, y = 10.0, z = 10.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE
    )

    let cube_position = rl.Vector3(x = 0.0, y = 1.0, z = 0.0)
    let cube_size = rl.Vector3(x = 2.0, y = 2.0, z = 2.0)

    var ray = zero[rl.Ray]
    var collision = zero[rl.RayCollision]

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_cursor_hidden():
            rl.update_camera(camera, rl.CameraMode.CAMERA_FIRST_PERSON)

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_RIGHT):
            if rl.is_cursor_hidden():
                rl.enable_cursor()
            else:
                rl.disable_cursor()

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            if not collision.hit:
                ray = rl.get_screen_to_world_ray(rl.get_mouse_position(), camera)
                collision = rl.get_ray_collision_box(
                    ray,
                    rl.BoundingBox(
                        min = rl.Vector3(
                            x = cube_position.x - cube_size.x / 2.0,
                            y = cube_position.y - cube_size.y / 2.0,
                            z = cube_position.z - cube_size.z / 2.0
                        ),
                        max = rl.Vector3(
                            x = cube_position.x + cube_size.x / 2.0,
                            y = cube_position.y + cube_size.y / 2.0,
                            z = cube_position.z + cube_size.z / 2.0
                        )
                    )
                )
            else:
                collision.hit = false

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        if collision.hit:
            rl.draw_cube(cube_position, cube_size.x, cube_size.y, cube_size.z, rl.RED)
            rl.draw_cube_wires(cube_position, cube_size.x, cube_size.y, cube_size.z, rl.MAROON)
            rl.draw_cube_wires(cube_position, cube_size.x + 0.2, cube_size.y + 0.2, cube_size.z + 0.2, rl.GREEN)
        else:
            rl.draw_cube(cube_position, cube_size.x, cube_size.y, cube_size.z, rl.GRAY)
            rl.draw_cube_wires(cube_position, cube_size.x, cube_size.y, cube_size.z, rl.DARKGRAY)

        rl.draw_ray(ray, rl.MAROON)
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        rl.draw_text("Try clicking on the box with your mouse!", 240, 10, 20, rl.DARKGRAY)
        if collision.hit:
            let label = "BOX SELECTED"
            rl.draw_text(
                label,
                (SCREEN_WIDTH - rl.measure_text(label, 30)) / 2,
                int<-((float<-SCREEN_HEIGHT) * 0.1),
                30,
                rl.GREEN
            )

        rl.draw_text("Right click mouse to toggle camera controls", 10, 430, 10, rl.GRAY)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
