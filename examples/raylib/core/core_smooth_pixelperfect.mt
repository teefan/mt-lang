module examples.raylib.core.core_smooth_pixelperfect

import std.c.libm as math
import std.c.raylib as rl

const screen_width: i32 = 800
const screen_height: i32 = 450
const virtual_screen_width: i32 = 160
const virtual_screen_height: i32 = 90
const virtual_ratio: f32 = f32<-screen_width / virtual_screen_width
const window_title: cstr = c"raylib [core] example - smooth pixelperfect"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var world_space_camera = zero[rl.Camera2D]()
    world_space_camera.zoom = 1.0

    var screen_space_camera = zero[rl.Camera2D]()
    screen_space_camera.zoom = 1.0

    let target = rl.LoadRenderTexture(virtual_screen_width, virtual_screen_height)
    defer rl.UnloadRenderTexture(target)

    let rec01 = rl.Rectangle(x = 70.0, y = 35.0, width = 20.0, height = 20.0)
    let rec02 = rl.Rectangle(x = 90.0, y = 55.0, width = 30.0, height = 10.0)
    let rec03 = rl.Rectangle(x = 80.0, y = 65.0, width = 15.0, height = 25.0)

    let source_rec = rl.Rectangle(
        x = 0.0,
        y = 0.0,
        width = f32<-target.texture.width,
        height = -f32<-target.texture.height,
    )
    let dest_rec = rl.Rectangle(
        x = -virtual_ratio,
        y = -virtual_ratio,
        width = f32<-screen_width + virtual_ratio * 2.0,
        height = f32<-screen_height + virtual_ratio * 2.0,
    )
    let origin = rl.Vector2(x = 0.0, y = 0.0)

    var rotation: f32 = 0.0
    var camera_x: f32 = 0.0
    var camera_y: f32 = 0.0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rotation += 60.0 * rl.GetFrameTime()

        let time = f32<-rl.GetTime()
        camera_x = math.sinf(time) * 50.0 - 10.0
        camera_y = math.cosf(time) * 30.0

        screen_space_camera.target = rl.Vector2(x = camera_x, y = camera_y)

        world_space_camera.target.x = math.truncf(screen_space_camera.target.x)
        screen_space_camera.target.x -= world_space_camera.target.x
        screen_space_camera.target.x *= virtual_ratio

        world_space_camera.target.y = math.truncf(screen_space_camera.target.y)
        screen_space_camera.target.y -= world_space_camera.target.y
        screen_space_camera.target.y *= virtual_ratio

        rl.BeginTextureMode(target)
        rl.ClearBackground(rl.RAYWHITE)

        rl.BeginMode2D(world_space_camera)
        rl.DrawRectanglePro(rec01, origin, rotation, rl.BLACK)
        rl.DrawRectanglePro(rec02, origin, -rotation, rl.RED)
        rl.DrawRectanglePro(rec03, origin, rotation + 45.0, rl.BLUE)
        rl.EndMode2D()

        rl.EndTextureMode()

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RED)

        rl.BeginMode2D(screen_space_camera)
        rl.DrawTexturePro(target.texture, source_rec, dest_rec, origin, 0.0, rl.WHITE)
        rl.EndMode2D()

        rl.DrawText(rl.TextFormat(c"Screen resolution: %ix%i", screen_width, screen_height), 10, 10, 20, rl.DARKBLUE)
        rl.DrawText(rl.TextFormat(c"World resolution: %ix%i", virtual_screen_width, virtual_screen_height), 10, 40, 20, rl.DARKGREEN)
        rl.DrawFPS(rl.GetScreenWidth() - 95, 10)

    return 0