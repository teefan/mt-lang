import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450


function player_box(position: rl.Vector3, size: rl.Vector3) -> rl.BoundingBox:
    return rl.BoundingBox(
        min = rl.Vector3(
            x = position.x - size.x / 2.0,
            y = position.y - size.y / 2.0,
            z = position.z - size.z / 2.0,
        ),
        max = rl.Vector3(
            x = position.x + size.x / 2.0,
            y = position.y + size.y / 2.0,
            z = position.z + size.z / 2.0,
        ),
    )


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - box collisions")
    defer rl.close_window()

    let camera = rl.Camera3D(
        position = rl.Vector3(x = 0.0, y = 10.0, z = 10.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var player_position = rl.Vector3(x = 0.0, y = 1.0, z = 2.0)
    let player_size = rl.Vector3(x = 1.0, y = 2.0, z = 1.0)
    var player_color = rl.GREEN

    let enemy_box_pos = rl.Vector3(x = -4.0, y = 1.0, z = 0.0)
    let enemy_box_size = rl.Vector3(x = 2.0, y = 2.0, z = 2.0)

    let enemy_sphere_pos = rl.Vector3(x = 4.0, y = 0.0, z = 0.0)
    let enemy_sphere_size = float<-1.5

    rl.set_target_fps(60)

    while not rl.window_should_close():
        if rl.is_key_down(rl.KeyboardKey.KEY_RIGHT):
            player_position.x += 0.2
        else if rl.is_key_down(rl.KeyboardKey.KEY_LEFT):
            player_position.x -= 0.2
        else if rl.is_key_down(rl.KeyboardKey.KEY_DOWN):
            player_position.z += 0.2
        else if rl.is_key_down(rl.KeyboardKey.KEY_UP):
            player_position.z -= 0.2

        let player_bounds = player_box(player_position, player_size)
        let enemy_box_bounds = player_box(enemy_box_pos, enemy_box_size)
        let collision = rl.check_collision_boxes(player_bounds, enemy_box_bounds) or rl.check_collision_box_sphere(player_bounds, enemy_sphere_pos, enemy_sphere_size)
        player_color = if collision: rl.RED else: rl.GREEN

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_cube(enemy_box_pos, enemy_box_size.x, enemy_box_size.y, enemy_box_size.z, rl.GRAY)
        rl.draw_cube_wires(enemy_box_pos, enemy_box_size.x, enemy_box_size.y, enemy_box_size.z, rl.DARKGRAY)
        rl.draw_sphere(enemy_sphere_pos, enemy_sphere_size, rl.GRAY)
        rl.draw_sphere_wires(enemy_sphere_pos, enemy_sphere_size, 16, 16, rl.DARKGRAY)
        rl.draw_cube_v(player_position, player_size, player_color)
        rl.draw_grid(10, 1.0)
        rl.end_mode_3d()

        rl.draw_text("Move player with arrow keys to collide", 220, 40, 20, rl.GRAY)
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
