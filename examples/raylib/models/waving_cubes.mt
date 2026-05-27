import std.math as math
import std.raylib as rl


const SCREEN_WIDTH: int = 800
const SCREEN_HEIGHT: int = 450
const NUM_BLOCKS: int = 15


function main() -> int:
    rl.init_window(SCREEN_WIDTH, SCREEN_HEIGHT, "raylib [models] example - waving cubes")
    defer rl.close_window()

    var camera = rl.Camera3D(
        position = rl.Vector3(x = 30.0, y = 20.0, z = 30.0),
        target = rl.Vector3(x = 0.0, y = 0.0, z = 0.0),
        up = rl.Vector3(x = 0.0, y = 1.0, z = 0.0),
        fovy = 70.0,
        projection = int<-rl.CameraProjection.CAMERA_PERSPECTIVE,
    )

    rl.set_target_fps(60)

    while not rl.window_should_close():
        let time = rl.get_time()
        let scale = (2.0 + float<-math.sin(time)) * 0.7
        let camera_time = time * 0.3

        camera.position.x = float<-(math.cos(camera_time) * 40.0)
        camera.position.z = float<-(math.sin(camera_time) * 40.0)

        rl.begin_drawing()
        rl.clear_background(rl.RAYWHITE)

        rl.begin_mode_3d(camera)
        rl.draw_grid(10, 5.0)

        var x = 0
        while x < NUM_BLOCKS:
            var y = 0
            while y < NUM_BLOCKS:
                var z = 0
                while z < NUM_BLOCKS:
                    let block_scale = float<-(x + y + z) / 30.0
                    let scatter = float<-math.sin(double<-(block_scale * 20.0) + (time * 4.0))
                    let cube_pos = rl.Vector3(
                        x = float<-(x - float<-NUM_BLOCKS / 2.0) * (scale * 3.0) + scatter,
                        y = float<-(y - float<-NUM_BLOCKS / 2.0) * (scale * 2.0) + scatter,
                        z = float<-(z - float<-NUM_BLOCKS / 2.0) * (scale * 3.0) + scatter,
                    )
                    let cube_color = rl.color_from_hsv(float<-(((x + y + z) * 18) % 360), 0.75, 0.9)
                    let cube_size = (2.4 - scale) * block_scale
                    rl.draw_cube(cube_pos, cube_size, cube_size, cube_size, cube_color)
                    z += 1
                y += 1
            x += 1

        rl.end_mode_3d()
        rl.draw_fps(10, 10)
        rl.end_drawing()

    return 0
