module examples.raylib.core.core_3d_camera_split_screen

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [core] example - 3d camera split screen"
const player_one_text: cstr = c"PLAYER1: W/S to move"
const player_two_text: cstr = c"PLAYER2: UP/DOWN to move"


def draw_scene(player_one_position: rl.Vector3, player_two_position: rl.Vector3, count: i32, spacing: f32) -> void:
    rl.DrawPlane(rl.Vector3(x = 0.0, y = 0.0, z = 0.0), rl.Vector2(x = 50.0, y = 50.0), rl.BEIGE)

    var x_index = -count
    while x_index <= count:
        var z_index = -count
        while z_index <= count:
            let world_x = spacing * x_index
            let world_z = spacing * z_index

            rl.DrawCube(rl.Vector3(x = world_x, y = 1.5, z = world_z), 1.0, 1.0, 1.0, rl.LIME)
            rl.DrawCube(rl.Vector3(x = world_x, y = 0.5, z = world_z), 0.25, 1.0, 0.25, rl.BROWN)

            z_index += 1
        x_index += 1

    rl.DrawCube(player_one_position, 1.0, 1.0, 1.0, rl.RED)
    rl.DrawCube(player_two_position, 1.0, 1.0, 1.0, rl.BLUE)


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera_player1 = rl.Camera3D(
        position = rl.Vector3(x = 0.0, y = 1.0, z = -3.0),
        target = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )
    let screen_player1 = rl.LoadRenderTexture(screen_width / 2, screen_height)
    defer rl.UnloadRenderTexture(screen_player1)

    var camera_player2 = rl.Camera3D(
        position = rl.Vector3(x = -3.0, y = 3.0, z = 0.0),
        target = rl.Vector3(x = 0.0, y = 3.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )
    let screen_player2 = rl.LoadRenderTexture(screen_width / 2, screen_height)
    defer rl.UnloadRenderTexture(screen_player2)

    let split_screen_rect = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = screen_player1.texture.width,
        height = -screen_player1.texture.height,
    )
    let count = 5
    let spacing: f32 = 4.0
    let overlay_alpha: f32 = 0.8

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let offset_this_frame: f32 = 10.0 * rl.GetFrameTime()

        if rl.IsKeyDown(rl.KeyboardKey.KEY_W):
            camera_player1.position.z += offset_this_frame
            camera_player1.target.z += offset_this_frame
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_S):
            camera_player1.position.z -= offset_this_frame
            camera_player1.target.z -= offset_this_frame

        if rl.IsKeyDown(rl.KeyboardKey.KEY_UP):
            camera_player2.position.x += offset_this_frame
            camera_player2.target.x += offset_this_frame
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN):
            camera_player2.position.x -= offset_this_frame
            camera_player2.target.x -= offset_this_frame

        rl.BeginTextureMode(screen_player1)
        rl.ClearBackground(rl.SKYBLUE)
        rl.BeginMode3D(camera_player1)
        draw_scene(camera_player1.position, camera_player2.position, count, spacing)
        rl.EndMode3D()
        rl.DrawRectangle(0, 0, screen_width / 2, 40, rl.Fade(rl.RAYWHITE, overlay_alpha))
        rl.DrawText(player_one_text, 10, 10, 20, rl.MAROON)
        rl.EndTextureMode()

        rl.BeginTextureMode(screen_player2)
        rl.ClearBackground(rl.SKYBLUE)
        rl.BeginMode3D(camera_player2)
        draw_scene(camera_player1.position, camera_player2.position, count, spacing)
        rl.EndMode3D()
        rl.DrawRectangle(0, 0, screen_width / 2, 40, rl.Fade(rl.RAYWHITE, overlay_alpha))
        rl.DrawText(player_two_text, 10, 10, 20, rl.DARKBLUE)
        rl.EndTextureMode()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)
        rl.DrawTextureRec(screen_player1.texture, split_screen_rect, rl.Vector2(x = 0.0, y = 0.0), rl.WHITE)
        rl.DrawTextureRec(screen_player2.texture, split_screen_rect, rl.Vector2(x = 0.5 * screen_width, y = 0.0), rl.WHITE)
        rl.DrawRectangle(rl.GetScreenWidth() / 2 - 2, 0, 4, rl.GetScreenHeight(), rl.LIGHTGRAY)

    return 0
