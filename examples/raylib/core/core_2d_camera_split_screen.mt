module examples.raylib.core.core_2d_camera_split_screen

import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 440
const player_size: i32 = 40
const window_title: cstr = c"raylib [core] example - 2d camera split screen"
const player_one_text: cstr = c"PLAYER1: W/S/A/D to move"
const player_two_text: cstr = c"PLAYER2: UP/DOWN/LEFT/RIGHT to move"

def draw_grid() -> void:
    var column = 0
    while column < screen_width / player_size + 1:
        let x = player_size * column
        rl.DrawLineV(rl.Vector2(x = x, y = 0.0), rl.Vector2(x = x, y = screen_height), rl.LIGHTGRAY)
        column += 1

    var row = 0
    while row < screen_height / player_size + 1:
        let y = player_size * row
        rl.DrawLineV(rl.Vector2(x = 0.0, y = y), rl.Vector2(x = screen_width, y = y), rl.LIGHTGRAY)
        row += 1

def draw_camera_scene(camera: rl.Camera2D, player1: rl.Rectangle, player2: rl.Rectangle) -> void:
    rl.BeginMode2D(camera)
    draw_grid()
    rl.DrawRectangleRec(player1, rl.RED)
    rl.DrawRectangleRec(player2, rl.BLUE)
    rl.EndMode2D()

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var player1 = rl.Rectangle(x = 200.0, y = 200.0, width = player_size, height = player_size)
    var player2 = rl.Rectangle(x = 250.0, y = 200.0, width = player_size, height = player_size)

    var camera1 = rl.Camera2D(
        target = rl.Vector2(x = player1.x, y = player1.y),
        offset = rl.Vector2(x = 200.0, y = 200.0),
        rotation = 0.0,
        zoom = 1.0,
    )
    var camera2 = rl.Camera2D(
        target = rl.Vector2(x = player2.x, y = player2.y),
        offset = rl.Vector2(x = 200.0, y = 200.0),
        rotation = 0.0,
        zoom = 1.0,
    )

    let screen_camera1 = rl.LoadRenderTexture(screen_width / 2, screen_height)
    defer rl.UnloadRenderTexture(screen_camera1)
    let screen_camera2 = rl.LoadRenderTexture(screen_width / 2, screen_height)
    defer rl.UnloadRenderTexture(screen_camera2)

    let split_screen_rect = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = screen_camera1.texture.width,
        height = -screen_camera1.texture.height,
    )
    let overlay_alpha: f32 = 0.6

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyDown(rl.KeyboardKey.KEY_S):
            player1.y += 3.0
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_W):
            player1.y -= 3.0
        if rl.IsKeyDown(rl.KeyboardKey.KEY_D):
            player1.x += 3.0
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_A):
            player1.x -= 3.0

        if rl.IsKeyDown(rl.KeyboardKey.KEY_UP):
            player2.y -= 3.0
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_DOWN):
            player2.y += 3.0
        if rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT):
            player2.x += 3.0
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT):
            player2.x -= 3.0

        camera1.target = rl.Vector2(x = player1.x, y = player1.y)
        camera2.target = rl.Vector2(x = player2.x, y = player2.y)

        rl.BeginTextureMode(screen_camera1)
        rl.ClearBackground(rl.RAYWHITE)
        draw_camera_scene(camera1, player1, player2)
        rl.DrawRectangle(0, 0, rl.GetScreenWidth() / 2, 30, rl.Fade(rl.RAYWHITE, overlay_alpha))
        rl.DrawText(player_one_text, 10, 10, 10, rl.MAROON)
        rl.EndTextureMode()

        rl.BeginTextureMode(screen_camera2)
        rl.ClearBackground(rl.RAYWHITE)
        draw_camera_scene(camera2, player1, player2)
        rl.DrawRectangle(0, 0, rl.GetScreenWidth() / 2, 30, rl.Fade(rl.RAYWHITE, overlay_alpha))
        rl.DrawText(player_two_text, 10, 10, 10, rl.DARKBLUE)
        rl.EndTextureMode()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.BLACK)
        rl.DrawTextureRec(screen_camera1.texture, split_screen_rect, rl.Vector2(x = 0.0, y = 0.0), rl.WHITE)
        rl.DrawTextureRec(screen_camera2.texture, split_screen_rect, rl.Vector2(x = 0.5 * screen_width, y = 0.0), rl.WHITE)
        rl.DrawRectangle(rl.GetScreenWidth() / 2 - 2, 0, 4, rl.GetScreenHeight(), rl.LIGHTGRAY)

    return 0
