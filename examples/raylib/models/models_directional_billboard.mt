module examples.raylib.models.models_directional_billboard

import std.c.libm as math
import std.c.raylib as rl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [models] example - directional billboard"
const skillbot_path: cstr = c"../resources/skillbot.png"
const animation_format: cstr = c"animation: %d"
const direction_frame_format: cstr = c"direction frame: %.0f"

def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 2.0, y = 1.0, z = 2.0),
        target = rl.Vector3(x = 0.0, y = 0.5, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 45.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    let skillbot = rl.LoadTexture(skillbot_path)
    defer rl.UnloadTexture(skillbot)

    var anim_timer: f32 = 0.0
    var anim = 0

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        rl.UpdateCamera(raw(addr(camera)), rl.CameraMode.CAMERA_ORBITAL)

        anim_timer += rl.GetFrameTime()
        if anim_timer > 0.5:
            anim_timer = 0.0
            anim += 1

        if anim >= 4:
            anim = 0

        let reference = rl.Vector2(x = 2.0, y = 0.0)
        let relative = rl.Vector2(x = camera.position.x, y = camera.position.z)
        var dir = math.floorf((reference.angle(relative) / rl.PI) * 4.0 + 0.25)
        if dir < 0.0:
            dir = 8.0 + dir

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)

        rl.DrawGrid(10, 1.0)
        rl.DrawBillboardPro(
            camera,
            skillbot,
            rl.Rectangle(
                x = f32<-anim * 24.0,
                y = dir * 24.0,
                width = 24.0,
                height = 24.0,
            ),
            rm.Vector3.zero(),
            rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
            rl.Vector2(x = 1.0, y = 1.0),
            rl.Vector2(x = 0.5, y = 0.0),
            0.0,
            rl.WHITE,
        )

        rl.EndMode3D()

        rl.DrawText(rl.TextFormat(animation_format, anim), 10, 10, 20, rl.DARKGRAY)
        rl.DrawText(rl.TextFormat(direction_frame_format, dir), 10, 40, 20, rl.DARKGRAY)

    return 0
