module examples.raylib.models.models_box_collisions

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [models] example - box collisions"
const collision_help_text: cstr = c"Move player with arrow keys to collide"

def centered_box(position: rl.Vector3, size: rl.Vector3) -> rl.BoundingBox:
    let half = rl.Vector3(x = size.x / 2.0, y = size.y / 2.0, z = size.z / 2.0)
    return rl.BoundingBox(
        min = rl.Vector3(x = position.x - half.x, y = position.y - half.y, z = position.z - half.z),
        max = rl.Vector3(x = position.x + half.x, y = position.y + half.y, z = position.z + half.z),
    )

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    let camera = rl.Camera3D(
        position = rl.Vector3(x = 0.0, y = 10.0, z = 10.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    var player_position = rl.Vector3(x = 0.0, y = 1.0, z = 2.0)
    let player_size = rl.Vector3(x = 1.0, y = 2.0, z = 1.0)
    var player_color = rl.GREEN

    let enemy_box_pos = rl.Vector3(x = -4.0, y = 1.0, z = 0.0)
    let enemy_box_size = rl.Vector3(x = 2.0, y = 2.0, z = 2.0)
    let enemy_sphere_pos = rl.Vector3(x = 4.0, y = 0.0, z = 0.0)
    let enemy_sphere_size: f32 = 1.5

    var collision = false

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT):
            player_position.x += 0.2
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT):
            player_position.x -= 0.2
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN):
            player_position.z += 0.2
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_UP):
            player_position.z -= 0.2

        collision = false

        if rl.CheckCollisionBoxes(centered_box(player_position, player_size), centered_box(enemy_box_pos, enemy_box_size)):
            collision = true

        if rl.CheckCollisionBoxSphere(centered_box(player_position, player_size), enemy_sphere_pos, enemy_sphere_size):
            collision = true

        if collision:
            player_color = rl.RED
        else:
            player_color = rl.GREEN

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)

        rl.DrawCube(enemy_box_pos, enemy_box_size.x, enemy_box_size.y, enemy_box_size.z, rl.GRAY)
        rl.DrawCubeWires(enemy_box_pos, enemy_box_size.x, enemy_box_size.y, enemy_box_size.z, rl.DARKGRAY)

        rl.DrawSphere(enemy_sphere_pos, enemy_sphere_size, rl.GRAY)
        rl.DrawSphereWires(enemy_sphere_pos, enemy_sphere_size, 16, 16, rl.DARKGRAY)

        rl.DrawCubeV(player_position, player_size, player_color)
        rl.DrawGrid(10, 1.0)

        rl.EndMode3D()

        rl.DrawText(collision_help_text, 220, 40, 20, rl.GRAY)
        rl.DrawFPS(10, 10)

    return 0