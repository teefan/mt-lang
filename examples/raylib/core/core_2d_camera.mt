module examples.raylib.core.core_2d_camera

import std.c.libm as math
import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const building_count: i32 = 100
const window_title: cstr = c"raylib [core] example - 2d camera"
const screen_area_text: cstr = c"SCREEN AREA"
const controls_title: cstr = c"Free 2D camera controls:"
const controls_move: cstr = c"- Right/Left to move player"
const controls_zoom: cstr = c"- Mouse Wheel to Zoom in-out"
const controls_rotate: cstr = c"- A / S to Rotate"
const controls_reset: cstr = c"- R to reset Zoom and Rotation"


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var player = rl.Rectangle(x = 400.0, y = 280.0, width = 40.0, height = 40.0)
    var buildings = zero[array[rl.Rectangle, 100]]()
    var build_colors = zero[array[rl.Color, 100]]()
    var spacing = 0

    for index in range(0, building_count):
        let width = rl.GetRandomValue(50, 200)
        let height = rl.GetRandomValue(100, 800)
        buildings[index] = rl.Rectangle(
            x = -6000.0 + spacing,
            y = screen_height - 130.0 - height,
            width = width,
            height = height,
        )
        spacing += width
        build_colors[index] = rl.Color(
            r = rl.GetRandomValue(200, 240),
            g = rl.GetRandomValue(200, 240),
            b = rl.GetRandomValue(200, 250),
            a = 255,
        )

    var camera = rl.Camera2D(
        target = rl.Vector2(x = player.x + 20.0, y = player.y + 20.0),
        offset = rl.Vector2(x = screen_width / 2.0, y = screen_height / 2.0),
        rotation = 0.0,
        zoom = 1.0,
    )
    let overlay_alpha: f32 = 0.5

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        if rl.IsKeyDown(rl.KeyboardKey.KEY_RIGHT):
            player.x += 2.0
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_LEFT):
            player.x -= 2.0

        camera.target = rl.Vector2(x = player.x + 20.0, y = player.y + 20.0)

        if rl.IsKeyDown(rl.KeyboardKey.KEY_A):
            camera.rotation -= 1.0
        elif rl.IsKeyDown(rl.KeyboardKey.KEY_S):
            camera.rotation += 1.0

        if camera.rotation > 40.0:
            camera.rotation = 40.0
        elif camera.rotation < -40.0:
            camera.rotation = -40.0

        camera.zoom = math.expf(math.logf(camera.zoom) + rl.GetMouseWheelMove() * 0.1)
        if camera.zoom > 3.0:
            camera.zoom = 3.0
        elif camera.zoom < 0.1:
            camera.zoom = 0.1

        if rl.IsKeyPressed(rl.KeyboardKey.KEY_R):
            camera.zoom = 1.0
            camera.rotation = 0.0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode2D(camera)
        rl.DrawRectangle(-6000, 320, 13000, 8000, rl.DARKGRAY)
        for index in range(0, building_count):
            rl.DrawRectangleRec(buildings[index], build_colors[index])
        rl.DrawRectangleRec(player, rl.RED)
        rl.DrawLine(camera.target.x, -screen_height * 10, camera.target.x, screen_height * 10, rl.GREEN)
        rl.DrawLine(-screen_width * 10, camera.target.y, screen_width * 10, camera.target.y, rl.GREEN)
        rl.EndMode2D()

        rl.DrawText(screen_area_text, 640, 10, 20, rl.RED)

        rl.DrawRectangle(0, 0, screen_width, 5, rl.RED)
        rl.DrawRectangle(0, 5, 5, screen_height - 10, rl.RED)
        rl.DrawRectangle(screen_width - 5, 5, 5, screen_height - 10, rl.RED)
        rl.DrawRectangle(0, screen_height - 5, screen_width, 5, rl.RED)

        rl.DrawRectangle(10, 10, 250, 113, rl.Fade(rl.SKYBLUE, overlay_alpha))
        rl.DrawRectangleLines(10, 10, 250, 113, rl.BLUE)

        rl.DrawText(controls_title, 20, 20, 10, rl.BLACK)
        rl.DrawText(controls_move, 40, 40, 10, rl.DARKGRAY)
        rl.DrawText(controls_zoom, 40, 60, 10, rl.DARKGRAY)
        rl.DrawText(controls_rotate, 40, 80, 10, rl.DARKGRAY)
        rl.DrawText(controls_reset, 40, 100, 10, rl.DARKGRAY)

    return 0
