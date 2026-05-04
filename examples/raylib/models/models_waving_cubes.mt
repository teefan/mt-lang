module examples.raylib.models.models_waving_cubes

import std.c.raylib as rl
import std.raylib.math as rm

const screen_width: i32 = 800
const screen_height: i32 = 450
const window_title: cstr = c"raylib [models] example - waving cubes"
const num_blocks: i32 = 15


def main() -> i32:
    rl.InitWindow(screen_width, screen_height, window_title)
    defer rl.CloseWindow()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 30.0, y = 20.0, z = 30.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 70.0,
        projection = rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    rl.SetTargetFPS(60)

    while not rl.WindowShouldClose():
        let time = f32<-rl.GetTime()
        let scale = (2.0 + rm.sin(time)) * 0.7
        let camera_time = time * 0.3
        let half_blocks = f32<-num_blocks / 2.0

        camera.position.x = rm.cos(camera_time) * 40.0
        camera.position.z = rm.sin(camera_time) * 40.0

        rl.BeginDrawing()
        defer rl.EndDrawing()

        rl.ClearBackground(rl.RAYWHITE)
        rl.BeginMode3D(camera)

        rl.DrawGrid(10, 5.0)

        for x in 0..num_blocks:
            for y in 0..num_blocks:
                for z in 0..num_blocks:
                    let block_scale = f32<-(x + y + z) / 30.0
                    let scatter = rm.sin(block_scale * 20.0 + time * 4.0)
                    let cube_pos = rl.Vector3(
                        x = (f32<-x - half_blocks) * (scale * 3.0) + scatter,
                        y = (f32<-y - half_blocks) * (scale * 2.0) + scatter,
                        z = (f32<-z - half_blocks) * (scale * 3.0) + scatter,
                    )
                    let cube_color = rl.ColorFromHSV(f32<-(((x + y + z) * 18) % 360), 0.75, 0.9)
                    let cube_size = (2.4 - scale) * block_scale
                    rl.DrawCube(cube_pos, cube_size, cube_size, cube_size, cube_color)

        rl.EndMode3D()
        rl.DrawFPS(10, 10)

    return 0
