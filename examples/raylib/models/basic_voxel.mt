import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const WORLD_SIZE: int = 8


function voxel_bounds(x: int, y: int, z: int) -> rl.BoundingBox:
    let position = rl.Vector3(x = float<-x, y = float<-y, z = float<-z)
    return rl.BoundingBox(
        min = rl.Vector3(x = position.x - 0.5, y = position.y - 0.5, z = position.z - 0.5),
        max = rl.Vector3(x = position.x + 0.5, y = position.y + 0.5, z = position.z + 0.5),
    )


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - basic voxel")
    defer rl.close_window()

    rl.disable_cursor()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = -2.0, y = 0.0, z = -2.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let cube_model = rl.load_model_from_mesh(rl.gen_mesh_cube(1.0, 1.0, 1.0))
    defer rl.unload_model(cube_model)

    var voxels: array[array[array[bool, WORLD_SIZE], WORLD_SIZE], WORLD_SIZE] = zero[array[array[array[bool, WORLD_SIZE], WORLD_SIZE], WORLD_SIZE]]
    var x = 0
    while x < WORLD_SIZE:
        var y = 0
        while y < WORLD_SIZE:
            var z = 0
            while z < WORLD_SIZE:
                voxels[x][y][z] = true
                z += 1
            y += 1
        x += 1

    rl.set_target_fps(60)

    while not rl.window_should_close():
        rl.update_camera(camera, rl.CameraMode.CAMERA_FIRST_PERSON)

        if rl.is_mouse_button_pressed(rl.MouseButton.MOUSE_BUTTON_LEFT):
            let screen_center = rl.Vector2(x = float<-rl.get_screen_width() / 2.0, y = float<-rl.get_screen_height() / 2.0)
            let ray = rl.get_screen_to_world_ray(screen_center, camera)

            var closest_distance = float<-99999.0
            var closest_x = -1
            var closest_y = -1
            var closest_z = -1

            x = 0
            while x < WORLD_SIZE:
                var y = 0
                while y < WORLD_SIZE:
                    var z = 0
                    while z < WORLD_SIZE:
                        if not voxels[x][y][z]:
                            z += 1
                            continue

                        let collision = rl.get_ray_collision_box(ray, voxel_bounds(x, y, z))
                        if collision.hit and collision.distance < closest_distance:
                            closest_distance = collision.distance
                            closest_x = x
                            closest_y = y
                            closest_z = z
                        z += 1
                    y += 1
                x += 1

            if closest_x >= 0:
                voxels[closest_x][closest_y][closest_z] = false

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_grid(10, 1.0)

        x = 0
        while x < WORLD_SIZE:
            var y = 0
            while y < WORLD_SIZE:
                var z = 0
                while z < WORLD_SIZE:
                    if not voxels[x][y][z]:
                        z += 1
                        continue

                    let position = rl.Vector3(x = float<-x, y = float<-y, z = float<-z)
                    rl.draw_model(cube_model, position, 1.0, rl.BEIGE)
                    rl.draw_cube_wires(position, 1.0, 1.0, 1.0, rl.BLACK)
                    z += 1
                y += 1
            x += 1

        rl.end_mode_3d()

        rl.draw_circle(rl.get_screen_width() / 2, rl.get_screen_height() / 2, 4.0, rl.RED)
        rl.draw_text("Left-click a voxel to remove it!", 10, 10, 20, rl.DARKGRAY)
        rl.draw_text("WASD to move, mouse to look around", 10, 35, 10, rl.GRAY)
        rl.end_drawing()

    return 0
